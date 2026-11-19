#!/usr/bin/env bash
# timeout: 300
# Where preemption by signal is built, a fork-join is not stopped for its
# own forks. A fork is a task bound by `t = f(x)&` that stays in its
# maker's frame and is waited for there (`task_record`). Its forks wait
# in its worker's queues all the time it runs, and the monitor's two
# looks 50 µs apart hurry only a fiber that is not a fork
# (`Worker.queued_woken`): on one worker, a quicksort whose forks wait
# behind every partition runs with no stop and the monitor looking about
# once a millisecond, not every 50 µs. Forks still count for the slice:
# a maker that spins on a flag its fork sets is stopped after one slice
# and the fork runs; a task held in a `Tasks` set is no fork, and a maker
# spinning on its flag is stopped at once. And on two workers, a fork
# left in a busy worker's slot while the other sleeps is taken by the
# other, which the monitor wakes, with no stop. Where preemption is not
# built, nothing runs.
source "$ROOT/test/cli/_lib.sh"
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64 | Darwin/arm64) ;;
    *) exit 0 ;;
esac

# A quicksort of 2^20 Ints on one worker: the high half of each
# partition is a fork, waited for once the low half is sorted; leaves of
# 4,096 are sorted by std.sort.
cat > qsort.rig <<'RIG'
use std.sort
use std.task
use std.time

fun qsort(xs: List[Int]) -> List[Int]
  if xs.len <= 4096
    new ys = <xs
    sort.sort(!ys[..])
    return ys
  pivot = xs[xs.len / 2]
  lo: List[Int] = List(capacity: xs.len / 2)
  mid: List[Int] = List()
  hi: List[Int] = List(capacity: xs.len / 2)
  for x in xs
    if x < pivot
      !lo.push(x)
    else if x > pivot
      !hi.push(x)
    else
      !mid.push(x)
  b = qsort(<hi)&
  out = qsort(<lo)
  !out.extend(?mid[..])
  high = >b
  !out.extend(?high[..])
  out

sub main()
  task.workers(1)
  m = 1 << 20
  ok = 1
  t = time.now()
  for round in 0..8
    ys: List[Int] = List(capacity: m)
    for i in 0..m
      !ys.push(((i +% round) *% 6364136223846793005 +% 1442695040888963407) >> 20)
    zs = qsort(<ys)
    for i in 1..zs.len
      ok = 0 if zs[i - 1] > zs[i]
  print(ok, t.elapsed() / 1_000_000)
RIG

out=$(RIG_PREEMPT_SLICE_US=1000000 RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 120 "$RIG" run --release qsort.rig 2>err-qsort.txt) || fail "qsort.rig (timeout 120 s): $out $(cat err-qsort.txt)"
read -r ok ms <<<"$out"
expect_eq "$ok" "1" "qsort.rig sorted"
pre=$(awk '/rig: worker 0:/ { for (i = 1; i <= NF; i++) if ($i == "preempted") print $(i + 1) + 0 }' err-qsort.txt)
# With a slice of a second, which no partition runs even on a loaded
# machine, nothing stops it; at 50 µs a look the monitor would look 20
# times a millisecond, at 1 ms about once.
[[ "$pre" == "0" ]] || fail "qsort.rig: a fork-join on one worker was stopped $pre times in $ms ms: $(cat err-qsort.txt)"
grep -q 'rig: monitor: looked' err-qsort.txt || fail "qsort.rig: no count of the monitor's looks: $(cat err-qsort.txt)"
looks=$(awk '/rig: monitor: looked/ { print $4 }' err-qsort.txt)
(( looks <= 3 * ms + 20 )) || fail "qsort.rig: the monitor looked $looks times in $ms ms: $(cat err-qsort.txt)"

# Taking turns on one worker: the maker spins on a flag its fork sets,
# with no waiting point. The fork waits for the slice, then the stop
# queues the maker behind it and it runs.
cat > turns.rig <<'RIG'
use std.task

fun setter(c: *Cell[Int]) -> Int
  !c.add(1)
  1

sub main()
  task.workers(1)
  c = *Cell(0)
  t = setter(+c)&
  spins = 0
  while c.get() == 0
    spins += 1
  print(>t, spins > 0)
RIG

out=$(RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 "$RIG" run --release turns.rig 2>err-turns.txt) || fail "turns.rig (timeout 60 s): $out $(cat err-turns.txt)"
expect_eq "$out" "1 true" "turns.rig"
grep -q 'preempted [1-9]' err-turns.txt || fail "turns.rig: the maker was not stopped: $(cat err-turns.txt)"

# With a slice of 200 ms, the maker spinning on its fork's flag runs the
# slice, and one spinning on the flag of a task held in a set, no fork,
# is stopped at the monitor's second look, well inside it.
cat > held.rig <<'RIG'
use std.task
use std.time

fun setter(c: *Cell[Int]) -> Int
  !c.add(1)
  1

sub main()
  task.workers(1)
  c = *Cell(0)
  d = *Cell(0)
  spins = 0
  t0 = time.now()
  t = setter(+c)&
  while c.get() == 0
    spins += 1
  fork_ms = t0.elapsed() / 1_000_000
  ts = Tasks[Int]()
  t1 = time.now()
  !ts.add(setter(+d)&)
  while d.get() == 0
    spins += 1
  held_ms = t1.elapsed() / 1_000_000
  xs = >ts
  print(>t + xs.len + spins % 1, fork_ms, held_ms)
RIG
out=$(RIG_PREEMPT_SLICE_US=200000 RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 "$RIG" run --release held.rig 2>err-held.txt) || fail "held.rig (timeout 60 s): $out $(cat err-held.txt)"
read -r two fork_ms held_ms <<<"$out"
expect_eq "$two" "2" "held.rig"
(( fork_ms >= 150 )) || fail "held.rig: the maker spinning on its fork's flag was stopped after $fork_ms ms, inside the slice of 200"
(( held_ms < 100 )) || fail "held.rig: the maker spinning on the flag of a task in a set was stopped after $held_ms ms, not at the second look"

# On two workers: the maker computes while its fork waits in its slot
# and the other worker sleeps. The monitor wakes the other, which takes
# the fork; the maker is not stopped.
cat > spread.rig <<'RIG'
use std.task
use std.time

fun work(n: Int) -> Int
  s = 0
  for i in 0..n
    s +%= i *% 2654435761 % 1000
  s

sub main()
  task.workers(2)
  time.sleep(ms: 20)!
  n = 1 << 26
  t = work(n)&
  a = work(n)
  print(a == >t)
RIG

out=$(RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 "$RIG" run --release spread.rig 2>err-spread.txt) || fail "spread.rig (timeout 60 s): $out $(cat err-spread.txt)"
expect_eq "$out" "true" "spread.rig"
grep -q 'rig: worker 1: ran [1-9]' err-spread.txt || fail "spread.rig: the fork did not move to the other worker: $(cat err-spread.txt)"
grep -q 'rig: worker 0: .* preempted 0,' err-spread.txt || fail "spread.rig: the maker was stopped: $(cat err-spread.txt)"
exit 0
