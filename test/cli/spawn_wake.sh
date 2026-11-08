#!/usr/bin/env bash
# Tasks made in turn and then waited for in order, while the other
# workers sleep, start at once on those workers: the first runs on its
# maker's worker, handed it as the maker waits, and the others wait in
# its "run next" slots, which wakes a worker for them (`sched.spread`).
# A build preempted by signal has no yield check to hand them on, and
# without the wake they waited for the monitor, about 1 ms. Most of 8
# rounds must start all four within 300 µs of their maker's first.
source "$ROOT/test/cli/_lib.sh"

cat > wake.rig <<'RIG'
use std.task
use std.time

fun work(made: time.Instant, k: Int) -> Int
  late = made.elapsed()
  total = 0
  for i in 0..k
    total = (total + i * 3) % 1000003
  # Both in one, so the loop is not optimized away: how late it started,
  # in nanoseconds, and what it computed.
  late * 2000000 + total

fun most(a: Int, b: Int) -> Int
  a if a > b else b

# Eight rounds: how many of them started all four tasks within 300 µs.
fun rounds(k: Int) -> Int
  prompt = 0
  for _ in 0..8
    # This task computes, as a program does before it makes its tasks,
    # while every other worker goes to sleep.
    spun = work(time.now(), 4 * k)
    m = time.now()
    t1 = work(m, k)&
    t2 = work(m, k)&
    t3 = work(m, k)&
    t4 = work(m, k)&
    a = >t1
    b = >t2
    c = >t3
    d = >t4
    late = most(most(a, b), most(c, d)) / 2000000
    if late < 300000 and (a + b + c + d + spun) >= 0
      prompt += 1
  prompt

sub main()
  task.workers(4)
  r = rounds(20000000)&
  print(>r)
RIG

for mode in fast safe; do
    out=$("$TIMEOUT_CMD" 60 "$RIG" run --release=$mode wake.rig 2>err-$mode.txt) || fail "wake.rig, $mode (timeout 60 s): $out $(cat err-$mode.txt)"
    [[ "$out" =~ ^[0-9]+$ ]] || fail "wake.rig, $mode: not a count of rounds: $out $(cat err-$mode.txt)"
    (( out >= 5 )) || fail "wake.rig, $mode: in $out of 8 rounds, four tasks made and waited for in order all started within 300 µs (5 or more expected)"
done
echo ok
