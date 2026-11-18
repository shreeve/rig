#!/usr/bin/env bash
# A worker runs the newest of its "run next" fibers first, but no more
# than `lifo_limit` times in a row before it takes one from its ring
# (src/sched.zig, `next`), so a task that keeps making tasks cannot keep
# an older one waiting there. A marker task made before a producer that
# loops forever, making batches of eight tasks and waiting for them,
# runs within 2 s on one worker and on two, preempted by signal where
# that is built and with yield checks elsewhere.
source "$ROOT/test/cli/_lib.sh"

cat > fair.rig <<'RIG'
use std.task
use std.time

fun small(i: Int) -> Int
  i

fun producer(stop: *Cell[Int]) -> Int
  n = 0
  while stop.get() == 0
    ts = Tasks[Int]()
    for i in 0..8
      !ts.add(small(n + i)&)
    for x in >ts
      n += x % 2
  n

fun marker(at: *Cell[Int]) -> Int
  !at.add(1)
  0

sub main()!
  stop = *Cell(0)
  at = *Cell(0)
  m = marker(+at)&
  p = producer(+stop)&
  t = time.now()
  while at.get() == 0 and t.elapsed() < 2000000000
    time.sleep(ms: 1)!
  ran = at.get() != 0
  !stop.add(1)
  >m
  >p
  print("marker ran", ran)
RIG

"$RIG" build --release -o fair-plain fair.rig >build.txt 2>&1 || fail "build fair.rig: $(cat build.txt)"
builds="plain"
for b in $builds; do
    for w in 1 2; do
        for i in 1 2 3; do
            out=$(RIG_WORKERS=$w "$TIMEOUT_CMD" 60 ./fair-$b 2>&1) || fail "fair.rig $b, $w workers, run $i (timeout 60 s): $out"
            expect_eq "$out" "marker ran true" "fair.rig $b, $w workers, run $i: the marker ran within 2 s"
        done
    done
done
exit 0
