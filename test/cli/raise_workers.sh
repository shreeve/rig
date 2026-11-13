#!/usr/bin/env bash
# timeout: 120
# `task.workers(n)` after the first task, in a release build and with
# real threads, which `seeds:` cannot give: a task raises the workers
# one at a time while others make and steal tasks, so workers look at
# the ring of a worker whose thread has not begun. A fiber lost hangs
# the run, and one run twice fails the sum. New workers take work, and
# a raise racing `os.exit` neither crashes nor changes the exit status.
source "$ROOT/test/cli/_lib.sh"

cat > stress.rig <<'RIG'
use std.task
use std.time

fun step(i: Int) -> Int
  total = 0
  for j in 0..200
    total = (total + j * i) % 1000003
  1 if total >= 0 else 0

fun round(n: Int) -> Int
  ts = Tasks[Int]()
  for i in 0..n
    !ts.add(step(i)&)
  xs = >ts
  total = 0
  for x in xs
    total += x
  total

fun rounds(k: Int, n: Int) -> Int
  total = 0
  for _ in 0..k
    total += round(n)
  total

fun raise(top: Int) -> Bool
  all = true
  for n in 3..top + 1
    all = task.workers(n) and all
    time.sleep(us: 50) catch return false
  all

sub main()
  _ = task.workers(2)
  a = rounds(30, 400)&
  b = rounds(30, 400)&
  r = raise(32)&
  sum = >a + >b
  print(sum, >r, task.worker_count())
RIG
"$RIG" build --release -o stress stress.rig >build.txt 2>&1 || fail "build stress.rig: $(cat build.txt)"
end=$(( $(date +%s) + 20 ))
run=0
while (( run < 3 || $(date +%s) < end )); do
    run=$(( run + 1 ))
    out=$("$TIMEOUT_CMD" 60 ./stress 2>err.txt) || fail "stress run $run (status $?): $out $(tail -3 err.txt)"
    expect_eq "$out" "24000 true 32" "stress run $run"
done

cat > spread.rig <<'RIG'
use std.task

fun work(k: Int) -> Int
  total = 0
  for i in 0..k
    total = (total + i * 3) % 1000003
  total

sub main()
  _ = task.workers(1)
  first = work(1)&
  _ = >first
  print(task.workers(4))
  ts = Tasks[Int]()
  for _ in 0..64
    !ts.add(work(4000000)&)
  xs = >ts
  print(xs.len)
RIG
"$RIG" build --release -o spread spread.rig >build-s.txt 2>&1 || fail "build spread.rig: $(cat build-s.txt)"
out=$(RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 ./spread 2>stats.txt | tr '\n' ' ') || fail "spread: $out"
expect_eq "$out" "true 64 " "spread"
ran=$(grep -cE 'rig: worker [1-3]: ran [1-9]' stats.txt) || true
(( ran >= 2 )) || fail "spread: the raised workers ran no tasks: $(cat stats.txt)"

cat > exiting.rig <<'RIG'
use std.os
use std.task
use std.time

fun nap() -> Int
  time.sleep(ms: 1) catch return 0
  1

fun raise(top: Int) -> Bool
  all = true
  for n in 3..top + 1
    all = task.workers(n) and all
  all

sub main()
  _ = task.workers(2)
  ts = Tasks[Int]()
  for _ in 0..2000
    !ts.add(nap()&)
  xs = >ts
  r = raise(24)&
  print(xs.len)
  os.exit(3)
  print(>r)
RIG
"$RIG" build --release -o exiting exiting.rig >build-e.txt 2>&1 || fail "build exiting.rig: $(cat build-e.txt)"
for run in $(seq 1 30); do
    status=0
    out=$("$TIMEOUT_CMD" 60 ./exiting 2>err.txt) || status=$?
    [[ $status == 3 ]] || fail "exiting run $run: status $status: $(tail -3 err.txt)"
    expect_eq "$out" "2000" "exiting run $run"
done
cat > seeded.rig <<'RIG'
use std.task

fun one() -> Int
  1

test "a deterministic run keeps to one thread when asked for more"
  t = one()&
  _ = >t
  if task.workers(8)
    panic("a deterministic run raised its workers")
  if task.worker_count() != 1
    panic("a deterministic run has more than one thread")
RIG
"$RIG" test --seeds=5 seeded.rig >seeded.txt 2>&1 || fail "seeded: $(cat seeded.txt)"
echo ok
