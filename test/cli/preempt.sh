#!/usr/bin/env bash
# RIG_PREEMPT=signal and local tasks. A program that makes a local task
# keeps its yield checks whatever the option says, since local tasks
# share counts that are not atomic and take turns at their waits and
# yield checks; `bin/rig` says so in one line on stderr. Each program
# here prints what it prints without the option and ends: tasks that
# spin-wait on each other, local ones among them, on one worker. A
# program with no local task gets no such line.
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
    off=$("$TIMEOUT_CMD" 60 "$RIG" run --release=fast $p.rig 2>&1) || fail "$p.rig without the option: $off"
    on=$(RIG_PREEMPT=signal "$TIMEOUT_CMD" 60 "$RIG" run --release=fast $p.rig 2>err-$p.txt) || fail "$p.rig with the option (timeout 60 s): $on $(cat err-$p.txt)"
    expect_eq "$on" "$off" "$p.rig with RIG_PREEMPT=signal"
    grep -q "^rig: RIG_PREEMPT=signal ignored: this program makes local tasks ($p.rig:[0-9]*), which take turns at yield checks$" err-$p.txt || fail "$p.rig: no note that the option was ignored: $(cat err-$p.txt)"
done
off=$("$RIG" run --release=fast plain.rig 2>&1) || fail "plain.rig without the option: $off"
out=$(RIG_PREEMPT=signal "$RIG" run --release=fast plain.rig 2>err-plain.txt) || fail "plain.rig with the option: $out"
expect_eq "$out" "$off" "plain.rig with RIG_PREEMPT=signal"
! grep -q "RIG_PREEMPT" err-plain.txt || fail "plain.rig makes no local task, but: $(cat err-plain.txt)"
