#!/usr/bin/env bash
# Preemption by signal, the default where it is built, and local tasks.
# A program that makes a local task keeps its yield checks, since local
# tasks share counts that are not atomic and take turns at their waits
# and yield checks: its functions are not placed in the program's
# section, and it ends: tasks that spin-wait on each other, local ones
# among them, on one worker. A program with no local task is placed
# there where preemption is built.
source "$ROOT/test/cli/_lib.sh"

cat > hold.rig <<'RIG'
use std.task

obj Node
  v: Int

fun spinlocal(n: ?*Node, k: Int) -> Int
  total = n.v
  for i in 0..k
    total = (total + i * 7) % 1000003
  total

fun spin(k: Int) -> Int
  total = 0
  for i in 0..k
    total = (total + i * 3) % 1000003
  total

fun maker(k: Int) -> Int
  m = *Node(v: 2)
  t = spinlocal(?m, k)&
  s = spin(k)
  s + >t

sub main()
  task.workers(1)
  n = *Node(v: 1)
  q = maker(20000000)&
  p = spinlocal(?n, 20000000)&
  print(>p + >q)
RIG

cat > starve.rig <<'RIG'
use std.task

obj Node
  v: Int

fun setter(n: ?*Node, c: *Cell[Int], k: Int) -> Int
  total = n.v
  for i in 0..k
    total = (total + i * 7) % 1000003
  !c.add(1)
  total

fun idle(n: ?*Node) -> Int
  n.v

fun waiter(c: *Cell[Int]) -> Int
  m = *Node(v: 2)
  t = idle(?m)&
  spins = 0
  while c.get() == 0
    spins += 1
  >t + spins % 1

sub main()
  task.workers(1)
  n = *Node(v: 1)
  c = *Cell(0)
  q = waiter(+c)&
  p = setter(?n, +c, 20000000)&
  print(>p > 0, >q)
RIG

cat > ring.rig <<'RIG'
use std.task

obj Node
  v: Int

fun stage(n: ?*Node, inc: *Cell[Int], out: *Cell[Int]) -> Int
  spins = 0
  while inc.get() == 0
    spins += 1
  !out.add(1)
  n.v + spins % 1

fun last(inc: *Cell[Int], out: *Cell[Int]) -> Int
  spins = 0
  while inc.get() == 0
    spins += 1
  !out.add(1)
  3 + spins % 1

sub main()
  task.workers(1)
  n = *Node(v: 1)
  c1 = *Cell(0)
  c2 = *Cell(0)
  c3 = *Cell(0)
  c4 = *Cell(0)
  c = last(+c3, +c4)&
  b = stage(?n, +c2, +c3)&
  a = stage(?n, +c1, +c2)&
  !c1.add(1)
  print(>a + >b + >c, c4.get())
RIG

cat > spin.rig <<'RIG'
use std.task

fun setter(c: *Cell[Int]) -> Int
  !c.add(1)
  1

fun waiter(c: *Cell[Int]) -> Int
  spins = 0
  while c.get() == 0
    spins += 1
  spins % 1

sub main()
  task.workers(1)
  c = *Cell(0)
  p = setter(+c)&
  q = waiter(+c)&
  print(>q, >p)
RIG

cat > plain.rig <<'RIG'
use std.task

fun spin(k: Int) -> Int
  total = 0
  for i in 0..k
    total = (total + i * 3) % 1000003
  total

sub main()
  t = spin(1000)&
  print(>t)
RIG

for p in hold starve ring; do
    out=$("$TIMEOUT_CMD" 60 "$RIG" run --release=fast $p.rig 2>err-$p.txt) || fail "$p.rig (timeout 60 s): $out $(cat err-$p.txt)"
    [ ! -s err-$p.txt ] || fail "$p.rig wrote to stderr: $(cat err-$p.txt)"
    "$RIG" emit $p.rig > $p.zig 2>&1 || fail "emit $p.rig: $(cat $p.zig)"
    ! grep -q "linksection(rig.preempt_section)" $p.zig || fail "$p.rig makes local tasks, but its functions are placed for preemption"
done
out=$("$RIG" run --release=fast plain.rig 2>&1) || fail "plain.rig: $out"
expect_eq "$out" "498497" "plain.rig"
"$RIG" emit plain.rig > plain.zig 2>&1 || fail "emit plain.rig: $(cat plain.zig)"
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64 | Darwin/arm64)
        grep -q "linksection(rig.preempt_section)" plain.zig || fail "plain.rig makes no local task, but its functions are not placed for preemption" ;;
esac

# A task that spins on the only worker, waiting for one queued behind it,
# with no local task: where preemption is built (Linux x86-64, arm64
# macOS), a signal stops it and the other runs, and the scheduler's
# counts show a task preempted; elsewhere the yield checks hand over.
on=$(RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 "$RIG" run --release=fast spin.rig 2>err-spin.txt) || fail "spin.rig (timeout 60 s): $on $(cat err-spin.txt)"
expect_eq "$on" "0 1" "spin.rig"
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64 | Darwin/arm64)
        grep -q 'preempted [1-9]' err-spin.txt || fail "spin.rig: no task preempted: $(cat err-spin.txt)" ;;
esac

# Tasks that loop on `file.read`, which reads a regular file in the task
# and spends its time in system calls, outside the program's code where
# a signal stops nothing, hand over their workers at each read's waiting
# point when a signal has asked them to (`sched.atWaitingPoint`): a task
# sleeping 20 ms beside eight of them on four workers wakes in time,
# where it waited for seconds in about half the runs.
printf 'some bytes to read\n' > small.txt
cat > reads.rig <<'RIG'
use std.file
use std.task
use std.time

fun reader(k: Int, stop: *Cell[Int]) -> Int!
  n = 0
  while stop.get() == 0
    s = file.read("small.txt")! ?? String()
    n += s.len
    time.sleep(ms: k % 2)!
  n

fun sleeper() -> Int!
  t = time.now()
  time.sleep(ms: 20)!
  t.elapsed() / 1000000

sub main()!
  task.workers(4)
  stop = *Cell(0)
  r0 = reader(0, +stop)&
  r1 = reader(1, +stop)&
  r2 = reader(2, +stop)&
  r3 = reader(3, +stop)&
  r4 = reader(4, +stop)&
  r5 = reader(5, +stop)&
  r6 = reader(6, +stop)&
  r7 = reader(7, +stop)&
  q = sleeper()&
  ms = >q!
  !stop.add(1)
  total = >r0! + >r1! + >r2! + >r3! + >r4! + >r5! + >r6! + >r7!
  print("woke", ms < 2000, total > 0)
RIG
"$RIG" build --release=fast -o reads reads.rig >build-reads.txt 2>&1 || fail "build reads.rig: $(cat build-reads.txt)"
for i in 1 2 3 4 5; do
    out=$("$TIMEOUT_CMD" 60 ./reads 2>&1) || fail "reads.rig run $i (timeout 60 s): $out"
    expect_eq "$out" "woke true true" "reads.rig run $i: the sleeper woke within 2 s"
done

# A loop that spends its time in std.text's searches, Zig code, is
# stopped by a signal there as in the program's own code: in a build
# preempted, the searches are in the program's code section
# (std/text.zig, `rig.preempt_section`). A task sleeping 20 ms beside two
# such loops on one worker wakes in time, where it woke in 30 ms to
# 15.8 s (docs/history/records/2026-11/preempt/default-on-2026-11-06.md).
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64 | Darwin/arm64)
        cat > finds.rig <<'RIG'
use std.task
use std.text
use std.time

fun searcher(k: Int, stop: *Cell[Int]) -> Int!
  n = 0
  big = String()
  for i in 0..200000
    !big.push(U8(0x61 + (i * 7 + k) % 23))
  while stop.get() == 0
    n += text.find(big, "zzzq") ?? 1
  n

fun sleeper() -> Int!
  t = time.now()
  time.sleep(ms: 20)!
  t.elapsed() / 1000000

sub main()!
  task.workers(1)
  stop = *Cell(0)
  s0 = searcher(0, +stop)&
  s1 = searcher(1, +stop)&
  q = sleeper()&
  ms = >q!
  !stop.add(1)
  total = >s0! + >s1!
  print(ms, total > 0)
RIG
        "$RIG" build --release=fast -o finds finds.rig >build-finds.txt 2>&1 || fail "build finds.rig: $(cat build-finds.txt)"
        for i in 1 2 3 4 5; do
            out=$("$TIMEOUT_CMD" 60 ./finds 2>&1) || fail "finds.rig run $i (timeout 60 s): $out"
            [[ ${out#* } == true ]] || fail "finds.rig run $i: $out"
            (( ${out%% *} <= 100 )) || fail "finds.rig run $i: the sleeper woke after ${out%% *} ms, past 100 ms"
        done ;;
esac

# The trampoline is a frame like a call's: a trace taken where a fiber
# is preempted (`RIG_PREEMPT_TRACE=1`, the first preemption's) walks
# through it into the stopped code and on to the fiber's base. A debug
# build is preempted on arm64 macOS alone (Linux x86-64's debug builds
# use Zig's own backend, which takes no trampoline).
if [[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]]; then
    out=$(RIG_PREEMPT_TRACE=1 "$TIMEOUT_CMD" 120 "$RIG" run spin.rig 2>trace.txt) || fail "spin.rig, debug, with the trace: $out $(cat trace.txt)"
    expect_eq "$out" "0 1" "spin.rig, debug, with the trace"
    grep -q ' in preemptEntryArm ' trace.txt || fail "spin.rig: the trace has no trampoline: $(cat trace.txt)"
    n=$(grep -c ' in preemptEntryArm ' trace.txt)
    [[ $n == 1 ]] || fail "spin.rig: the trace walks the trampoline $n times: $(head -20 trace.txt)"
    grep -q ' in fiberMain ' trace.txt || fail "spin.rig: the trace stops at the trampoline: $(cat trace.txt)"
fi

# On arm64 macOS a program built to be preempted has its program section
# kept apart, whose functions Zig's own traces place only through the
# `.dSYM` that `dsymutil` writes after the link: a panic in the program's
# code shows its source line. Without Apple's command-line tools the
# build says so in a note, and the case is skipped.
if [[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]] && command -v dsymutil >/dev/null; then
    cat > boom.rig <<'RIG'
use std.task

fun deep(xs: ?List[Int], i: Int) -> Int
  xs[i] + 1

fun work(n: Int) -> Int
  xs = List[Int]()
  for i in 0..n
    !xs.push(i)
  deep(?xs, n + 3)

sub main()
  t = work(10)&
  print(>t)
RIG
    RIG_NO_CRASH_REPORT=1 "$TIMEOUT_CMD" 120 "$RIG" run boom.rig >boom.out 2>&1 && fail "boom.rig did not panic: $(cat boom.out)"
    grep -qE '__rig_main\.zig:[0-9]+:[0-9]+: 0x[0-9a-f]+ in deep ' boom.out || fail "boom.rig: the trace has no line for deep: $(head -30 boom.out)"
    # `dsymutil` runs once a link: the same build again copies the kept
    # executable, whose `.dSYM` is still its own.
    mkdir -p fake
    printf '#!/bin/sh\necho "$@" >> %s/dsymutil.log\nexec %s "$@"\n' "$PWD" "$(command -v dsymutil)" > fake/dsymutil
    chmod +x fake/dsymutil
    for k in 1 2; do
        PATH="$PWD/fake:$PATH" "$RIG" build -o boom-bin boom.rig >/dev/null 2>&1 || fail "build $k of boom.rig"
    done
    expect_eq "$(wc -l < dsymutil.log | tr -d ' ')" "1" "dsymutil runs for two builds of one package"
    [[ -d boom-bin.dSYM ]] || fail "boom-bin has no .dSYM"
fi
