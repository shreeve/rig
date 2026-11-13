#!/usr/bin/env bash
# timeout: 120
# `task.workers(n)` with a smaller n, in a release build on real threads,
# which `seeds:` cannot give: the workers past n park, and
# RIG_SCHED_STATS=1 shows they ran no task after (`ran 0 since`), while
# the two left run every task; tasks asleep on a worker that parks still
# wake; a raise after a lower unparks the workers, which take work again.
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
"$RIG" build --release=fast -o lower lower.rig >build.txt 2>&1 || fail "build lower.rig: $(cat build.txt)"
for run in 1 2 3; do
    out=$(RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 ./lower 2>stats.txt | tr '\n' ' ') || fail "lower run $run: $out $(tail -3 stats.txt)"
    expect_eq "$out" "true 2 64 64 100 " "lower run $run"
    parked=$(grep -cE '^rig: worker [2-7]: .*, parked [1-9][0-9]*, ran 0 since, gave back [0-9]* KiB$' stats.txt) || true
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
"$RIG" build --release=fast -o again again.rig >build-a.txt 2>&1 || fail "build again.rig: $(cat build-a.txt)"
# Where a burst runs depends on the machine's load, as for a program
# that never lowered: a raised worker takes work in one of five runs.
woke=0
for run in 1 2 3 4 5; do
    out=$(RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 ./again 2>stats.txt | tr '\n' ' ') || fail "again: $out $(tail -3 stats.txt)"
    expect_eq "$out" "64 true 64 true 8 64 " "again run $run"
    woke=$(grep -cE '^rig: worker [2-7]: .*, parked 1, ran [1-9][0-9]* since, gave back [0-9]* KiB$' stats.txt) || true
    (( woke >= 1 )) && break
done
(( woke >= 1 )) || fail "again: the raised workers ran no tasks after their park: $(tr '\n' '|' < stats.txt)"
echo ok
