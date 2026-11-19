#!/usr/bin/env bash
# timeout: 120
# When the workers start (docs/internals/scheduler.md): as `main` starts
# in a program that makes a task and never names `task.workers`, so its
# first tasks find them running; at its first task in one that names
# `task.workers`, which only sets how many start; never in a
# deterministic run or a program that makes no task. RIG_SCHED_STATS prints a line for each worker that started.
source "$ROOT/test/cli/_lib.sh"

# The task is never reached, and the workers started all the same.
cat >ahead.rig <<'RIG'
use std.os

fun one() -> Int
  1

sub main()
  if os.args().len > 5
    t = one()&
    print(>t)
  print("done")
RIG
# The program names `task.workers`: its workers wait for its first task.
cat >asked.rig <<'RIG'
use std.os
use std.task

fun one() -> Int
  1

sub main()
  if os.args().len > 1
    print(task.workers(3), task.workers(2), task.workers(5))
  if os.args().len > 5
    t = one()&
    print(>t)
  print("done")
RIG
cat >none.rig <<'RIG'
sub main()
  print("done")
RIG
for p in ahead asked none; do
    "$RIG" emit $p.rig >$p.zig 2>/dev/null || fail "rig emit $p.rig"
    "$RIG" build --release -o $p $p.rig >build.txt 2>&1 || fail "build $p.rig: $(cat build.txt)"
done
expect_has "$(cat ahead.zig)" "pub const __rig_start_early = true;" "a program that makes a task and names no task.workers"
grep -q "__rig_start_early" asked.zig && fail "a program that names task.workers starts its workers at its first task"
grep -q "__rig_start_early" none.zig && fail "a program that makes no task starts no workers"

# How many workers' lines a run prints.
started() { RIG_SCHED_STATS=1 "$@" 2>&1 >/dev/null | grep -c '^rig: worker [0-9]*: ran'; }

expect_eq "$(RIG_WORKERS=4 started ./ahead)" 4 "workers started as main started, RIG_WORKERS of them"
expect_eq "$(RIG_WORKERS=1 started ./ahead)" 1 "one worker is main's alone"
expect_eq "$(RIG_SEED=7 RIG_WORKERS=4 started ./ahead)" 1 "a deterministic run starts none"
expect_eq "$(RIG_WORKERS=4 started ./asked)" 1 "task.workers named and not called: none started"
expect_eq "$(RIG_WORKERS=4 ./asked x 2>&1)" "true true true
done" "task.workers before the first task sets the number each time"
expect_eq "$(RIG_WORKERS=4 started ./asked x)" 1 "task.workers called and no task made: none started"
expect_eq "$(RIG_WORKERS=4 started ./asked x x x x x)" 5 "the first task starts the last number set"
expect_eq "$(./none 2>&1)" "done" "a program that makes no task"

# A program that ends while its workers start neither hangs nor crashes.
for i in $(seq 1 200); do
    out=$("$TIMEOUT_CMD" 20 ./ahead 2>err.txt) || fail "ahead run $i (status $?): $(tail -3 err.txt)"
    expect_eq "$out" "done" "ahead run $i"
done
