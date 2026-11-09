#!/usr/bin/env bash
# Stack traces through preempted code, on arm64 macOS: the trampoline
# in a preempted fiber's trace, and the program's lines through the
# `.dSYM` written for its section kept apart.
source "$ROOT/test/cli/_lib.sh"

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
