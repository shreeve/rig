#!/usr/bin/env bash
# timeout: 120
# `task.workers(n)` with a smaller n, in a release build on real threads,
# which `seeds:` cannot give: the workers past n park, and
# RIG_SCHED_STATS=1 shows they ran no task after (`ran 0 since`), while
# the two left run every task; tasks asleep on a worker that parks still
# wake; a raise after a lower unparks the workers, which take work again.
# A worker that parks hands its heap's free memory over to the workers
# that go on (`, handed over N KiB`), and a program that goes on
# allocating on the two left grows its peak resident memory little.
source "$ROOT/test/cli/_lib.sh"

cat > lower.rig <<'RIG'
use std.task
use std.time

fun work(k: Int) -> Int
  total = 0
  for i in 0..k
    total = (total + i * 3) % 1000003
  1 if total >= 0 else 0

fun nap(ms: Int) -> Int
  time.sleep(ms: ms) catch return 0
  1

fun round(n: Int, k: Int) -> Int
  ts = Tasks[Int]()
  for _ in 0..n
    !ts.add(work(k)&)
  xs = >ts
  total = 0
  for x in xs
    total += x
  total

sub main()
  _ = task.workers(8)
  a = round(64, 2000000)
  naps = Tasks[Int]()
  for i in 0..100
    !naps.add(nap(5 + i % 20)&)
  print(task.workers(2), task.worker_count())
  b = round(64, 2000000)
  ys = >naps
  print(a, b, ys.len)
RIG
"$RIG" build --release -o lower lower.rig >build.txt 2>&1 || fail "build lower.rig: $(cat build.txt)"
for run in 1 2 3; do
    out=$(RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 ./lower 2>stats.txt | tr '\n' ' ') || fail "lower run $run: $out $(tail -3 stats.txt)"
    expect_eq "$out" "true 2 64 64 100 " "lower run $run"
    parked=$(grep -cE '^rig: worker [2-7]: .*, parked [1-9][0-9]*, ran 0 since, handed over [0-9]* KiB$' stats.txt) || true
    (( parked == 6 )) || fail "lower run $run: $parked of workers 2-7 parked and ran nothing after: $(tr '\n' '|' < stats.txt)"
    kept=$(grep -cE '^rig: worker [01]: .*parked' stats.txt) || true
    (( kept == 0 )) || fail "lower run $run: worker 0 or 1 parked: $(tr '\n' '|' < stats.txt)"
done

cat > again.rig <<'RIG'
use std.task

fun work(k: Int) -> Int
  total = 0
  for i in 0..k
    total = (total + i * 3) % 1000003
  1 if total >= 0 else 0

fun round(n: Int, k: Int) -> Int
  ts = Tasks[Int]()
  for _ in 0..n
    !ts.add(work(k)&)
  xs = >ts
  total = 0
  for x in xs
    total += x
  total

sub main()
  _ = task.workers(8)
  print(round(64, 200000))
  print(task.workers(2), round(64, 200000))
  print(task.workers(8), task.worker_count())
  print(round(64, 16000000))
RIG
"$RIG" build --release -o again again.rig >build-a.txt 2>&1 || fail "build again.rig: $(cat build-a.txt)"
# Where a burst runs depends on the machine's load, as for a program
# that never lowered: a raised worker takes work in one of five runs.
woke=0
for run in 1 2 3 4 5; do
    out=$(RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 ./again 2>stats.txt | tr '\n' ' ') || fail "again: $out $(tail -3 stats.txt)"
    expect_eq "$out" "64 true 64 true 8 64 " "again run $run"
    woke=$(grep -cE '^rig: worker [2-7]: .*, parked 1, ran [1-9][0-9]* since, handed over [0-9]* KiB$' stats.txt) || true
    (( woke >= 1 )) && break
done
(( woke >= 1 )) || fail "again: the raised workers ran no tasks after their park: $(tr '\n' '|' < stats.txt)"

# churn.rig with ROUNDS rounds on two workers after one on eight: each
# task builds small blocks, a List that grows through spans, and in one
# task a List of 16 MiB or more, a mapping of its own.
churn() {
    cat > "churn$1.rig" <<RIG
use std.task

fun churn(k: Int) -> Int
  rows: List[List[Int]] = List()
  for r in 0..2000
    row: List[Int] = List()
    for i in 0..(20 + r % 50)
      !row.push(i * k + r)
    !rows.push(<row)
  n = 2100000 if k == 0 else 400000
  big: List[Int] = List()
  for i in 0..n
    !big.push(i * 3 + k)
  1 if big[n - 1] == (n - 1) * 3 + k and rows.len == 2000 else 0

fun round() -> Int
  ts = Tasks[Int]()
  for k in 0..16
    !ts.add(churn(k)&)
  xs = >ts
  total = 0
  for x in xs
    total += x
  total

sub main()
  _ = task.workers(8)
  total = round()
  _ = task.workers(2)
  for _ in 0..$1
    total += round()
  print(total)
RIG
    "$RIG" build --release -o "churn$1" "churn$1.rig" >build-c.txt 2>&1 || fail "build churn$1.rig: $(cat build-c.txt)"
}
# Run ./churnN: its output in $out, its peak resident bytes in $rss, and
# its stats in stats.txt.
peak() {
    case $(uname) in
        Darwin)
            out=$(RIG_SCHED_STATS=1 /usr/bin/time -l "$TIMEOUT_CMD" 60 "./churn$1" 2>stats.txt) || fail "churn$1: $out $(tail -3 stats.txt)"
            rss=$(awk '/maximum resident set size/ { print $1 }' stats.txt) ;;
        *)
            out=$(RIG_SCHED_STATS=1 /usr/bin/time -v "$TIMEOUT_CMD" 60 "./churn$1" 2>stats.txt) || fail "churn$1: $out $(tail -3 stats.txt)"
            rss=$(( $(awk -F: '/Maximum resident set size/ { print $2 }' stats.txt) * 1024 )) ;;
    esac
}
churn 6
churn 24
peak 6
expect_eq "$out" "112" "churn6"
six=$rss
handed=$(grep -cE '^rig: worker [2-7]: .*, parked 1, ran 0 since, handed over [1-9][0-9]* KiB$' stats.txt) || true
(( handed >= 1 )) || fail "churn6: no parked worker handed memory over: $(tr '\n' '|' < stats.txt)"
peak 24
expect_eq "$out" "400" "churn24"
# Four times the rounds on the two workers left take their memory from
# what the parked workers handed over and from their own: the peak grows
# by at most half and 32 MiB (on the Mac, about a fifth; with the
# parked heaps trimmed rather than handed over, peaks run a third higher).
(( rss <= six + six / 2 + 32 * 1024 * 1024 )) || fail "churn24 peaked at $rss bytes resident, churn6 at $six"
echo ok
