#!/usr/bin/env bash
# timeout: 300
# PHASE-WIDE (scratch, measurement only; never lands): `task.widen()` and
# `task.narrow()` under RIG_WIDE=1, in release builds on real threads,
# which `seeds:` cannot give (a seeded run keeps to one thread, where both
# do nothing). Each program widens from two workers, runs work of one
# kind across the wide phase and a narrow, and checks what it computed:
# tasks, an actor called from many tasks, a channel's producers and
# consumers, tasks asleep on timers, `par`, a long loop running as the
# narrow parks its worker, and twenty widen/narrow cycles. Each runs
# several times with RIG_WIDE=1 and once without, where the worker count
# never moves, and once in a debug build under RIG_SANITIZE=1.
# NARROW-PLACE (scratch): every release run repeats under each arm's
# switches (RIG_SPREAD, RIG_PIN, RIG_GIVE), and on Linux a held program
# shows each worker on pinned to a core of its own after a narrow.
source "$ROOT/test/cli/_lib.sh"

cat > common.rig <<'RIG'

pub fun work(k: Int) -> Int
  s = 0
  for i in 0..200000
    s = (s +% i *% k) & 1048575
  s

pub fun batch(n: Int) -> Int
  ts = Tasks[Int]()
  for k in 0..n
    !ts.add(work(k)&)
  total = 0
  for x in >ts
    total += x
  total
RIG

cat > tasks.rig <<'RIG'
use std.task
use common

sub main()
  task.workers(2)
  a = common.batch(32)
  task.widen()
  b = common.batch(64)
  task.narrow()
  c = common.batch(64)
  print(a > 0, b == c, task.worker_count())
RIG

cat > actor.rig <<'RIG'
use std.task
use common

obj Tally
  total: Int

  fun add(!@, n: Int) -> Int
    @total += n
    @total

  fun get(?@) -> Int
    @total

fun hammer(t: *Actor[Tally], n: Int) -> Int
  for _ in 0..n
    _ = !t.add(1)
  1

sub main()
  task.workers(2)
  t = *Actor(Tally(total: 0))
  task.widen()
  ts = Tasks[Int]()
  for _ in 0..16
    !ts.add(hammer(+t, 5000)&)
  task.narrow()
  for _ in 0..16
    !ts.add(hammer(+t, 5000)&)
  n = 0
  for x in >ts
    n += x
  print(n, t.get(), task.worker_count())
RIG

cat > chan.rig <<'RIG'
use std.task
use common

sub produce(c: *Chan[Int], from: Int, n: Int)
  for i in 0..n
    !c.send(from + i) catch return

fun consume(c: *Chan[Int], n: Int) -> Int
  s = 0
  for _ in 0..n
    s += (!c).recv() catch none ?? 0
  s

sub main()
  task.workers(2)
  task.widen()
  c = *Chan[Int](16)
  ps = Tasks[Void]()
  for p in 0..8
    !ps.add(produce(+c, p * 1000, 1000)&)
  qs = Tasks[Int]()
  for _ in 0..4
    !qs.add(consume(+c, 2000)&)
  task.narrow()
  >ps
  total = 0
  for x in >qs
    total += x
  print(total, task.worker_count())
RIG

cat > naps.rig <<'RIG'
use std.task
use std.time
use common

fun nap(ms: Int) -> Int
  time.sleep(ms: ms) catch return 0
  1

sub main()
  task.workers(2)
  task.widen()
  ns = Tasks[Int]()
  for i in 0..200
    !ns.add(nap(1 + i % 15)&)
  _ = common.batch(16)
  task.narrow()
  n = 0
  for x in >ns
    n += x
  print(n, task.worker_count())
RIG

cat > par.rig <<'RIG'
use std.par
use std.task
use common

sub main()
  task.workers(2)
  task.widen()
  xs: List[Int] = List()
  for i in 0..20000
    !xs.push(i)
  ys = par.map(?xs, |x| common.work(x % 7) + x)
  task.narrow()
  zs = par.map(?xs, |x| common.work(x % 7) + x)
  same = true
  for i in 0..ys.len
    same = same and ys[i] == zs[i]
  print(ys.len, same, task.worker_count())
RIG

cat > loop.rig <<'RIG'
use std.task
use std.time

fun spin(ms: Int) -> Int
  t = time.monotonic()
  s = 0
  while Int(t.elapsed().ms()) < ms
    s = (s +% 7) & 1023
  1 if s >= 0 else 0

sub main()
  task.workers(2)
  task.widen()
  ts = Tasks[Int]()
  for _ in 0..8
    !ts.add(spin(60)&)
  time.sleep(ms: 10) catch print("")
  task.narrow()
  n = 0
  for x in >ts
    n += x
  print(n, task.worker_count())
RIG

cat > hold.rig <<'RIG'
use std.task
use std.time
use common

fun spin(k: Int) -> Int
  s = 0
  for i in 0..100000000
    s = (s +% i *% k) & 1048575
  s

sub main()
  task.workers(2)
  task.widen()
  total = common.batch(16)
  task.narrow()
  ts = Tasks[Int]()
  for k in 0..2
    !ts.add(spin(k + 1)&)
  for x in >ts
    total += x
  time.sleep(ms: 1500) catch return
  print(total > 0, task.worker_count())
RIG

cat > cycles.rig <<'RIG'
use std.task
use common

sub main()
  task.workers(2)
  total = 0
  for _ in 0..20
    task.widen()
    total += common.batch(8)
    task.narrow()
    total += common.batch(8)
  print(total > 0, task.worker_count())
RIG

expect() {
    local prog=$1 want=$2 env=$3 out
    out=$(env $env "$TIMEOUT_CMD" 60 ./$prog 2>err.txt | tr '\n' ' ') || fail "$prog ($env): $out $(tail -3 err.txt)"
    expect_eq "$out" "$want " "$prog ($env)"
}

for p in tasks actor chan naps par loop cycles hold; do
    "$RIG" build --release -o $p $p.rig >build.txt 2>&1 || fail "build $p.rig: $(cat build.txt)"
done
arms=("RIG_WIDE=1" "RIG_WIDE=1 RIG_SPREAD=1" "RIG_WIDE=1 RIG_SPREAD=1 RIG_PIN=1" "RIG_WIDE=1 RIG_SPREAD=1 RIG_PIN=1 RIG_GIVE=1" "RIG_WIDE=1 RIG_GIVE=1" "RIG_PIN=1")
for arm in "${arms[@]}"; do
    for run in 1 2 3; do
        n=2
        expect tasks "true true $n" "$arm"
        expect actor "32 160000 $n" "$arm"
        expect chan "31996000 $n" "$arm"
        expect naps "200 $n" "$arm"
        expect par "20000 true $n" "$arm"
        expect loop "8 $n" "$arm"
        expect cycles "true $n" "$arm"
    done
done
# Pinned after a narrow (Linux): the two workers on each run on one
# physical core's threads alone, different cores.
if [[ $(uname -s) == Linux ]]; then
    for arm in "RIG_WIDE=1 RIG_SPREAD=1 RIG_PIN=1" "RIG_WIDE=1 RIG_SPREAD=1 RIG_PIN=1 RIG_GIVE=1" "RIG_PIN=1"; do
        env $arm ./hold >hold.txt 2>&1 &
        pid=$!
        sleep 0.8
        all=$(grep Cpus_allowed_list /proc/self/status | awk '{print $2}')
        lists=$(for t in /proc/$pid/task/*; do grep Cpus_allowed_list $t/status | awk '{print $2}'; done | grep -vx "$all" | sort)
        wait $pid || fail "hold ($arm): $(cat hold.txt)"
        expect_eq "$(tr '\n' ' ' < hold.txt)" "true 2 " "hold ($arm)"
        pinned=$(echo "$lists" | grep -c . || true)
        distinct=$(echo "$lists" | sort -u | grep -c . || true)
        (( pinned >= 2 && distinct == pinned )) || fail "hold ($arm): workers not pinned one per core: all=$all pinned=[$(echo $lists)]"
    done
fi
# Off, the count never moves and the results are the same.
expect tasks "true true 2" RIG_WIDE=0
expect actor "32 160000 2" RIG_WIDE=0
expect cycles "true 2" RIG_WIDE=0
# Widened, the extra workers ran tasks, and parked after the narrow.
out=$(RIG_WIDE=1 RIG_SCHED_STATS=1 ./tasks 2>stats.txt) || fail "tasks stats: $out"
extra=$(grep -cE '^rig: worker [2-9]' stats.txt) || true
[[ $(uname -s) == Darwin ]] && fast=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo 2) || fast=$(nproc)
(( fast <= 2 || extra >= 1 )) || fail "tasks: no worker past the first two ran under RIG_WIDE=1: $(tr '\n' '|' < stats.txt)"
# A debug build, leak-checked and sanitized.
for p in actor naps cycles; do
    out=$(RIG_WIDE=1 RIG_SANITIZE=1 "$TIMEOUT_CMD" 120 "$RIG" run $p.rig 2>err.txt | tr '\n' ' ') || fail "$p debug: $out $(tail -5 err.txt)"
done
echo ok
