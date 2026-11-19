#!/usr/bin/env bash
# timeout: 300
# The fork deques race on real workers (`sched.Forks`): a tree sum whose
# every level forks, down to single Ints, so each worker's fiber pushes
# and takes back forks while idle workers steal the oldest, at 2 to 8
# workers, in a release build and a sanitized debug one. Every sum must
# be right and leak-free; and, counted by `RIG_SCHED_STATS=1`, forks
# must have run inline and been stolen both. Tasks waking from timers
# all the while put woken fibers in the "run next" slots and the rings,
# so slots, ring and deque race together. formal/Models/Deque.lean
# checks the orders the deque's code uses; this runs them.
source "$ROOT/test/cli/_lib.sh"

cat > race.rig <<'RIG'
use std.task
use std.time

fun tree(lo: Int, hi: Int) -> Int
  return lo if hi - lo == 1
  mid = lo + (hi - lo) / 2
  b = tree(mid, hi)&
  a = tree(lo, mid)
  a + >b

fun waker(n: Int) -> Int
  for _ in 0..n
    time.sleep(us: 200) catch return 0
  n

sub main()
  ws = Tasks[Int]()
  for _ in 0..3
    !ws.add(waker(100)&)
  n = 1 << 14
  ok = 0
  for _ in 0..20
    ok += 1 if tree(0, n) == n * (n - 1) / 2
  woke = 0
  for x in >ws
    woke += x
  print(ok, woke)
RIG

# The sum of every worker's count `what` in the stats on stderr `err`.
count() { sed -n "s/.*[ ,]$1 \([0-9]*\).*/\1/p" "$2" | paste -sd+ - | bc; }

"$RIG" build --release -o race-release race.rig || fail "race.rig: release build"
"$RIG" build -o race-debug race.rig || fail "race.rig: debug build"

stole=0; inlined=0
for w in 2 3 4 8; do
    for k in 1 2 3; do
        out=$(RIG_WORKERS=$w RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 ./race-release 2>err.txt) || fail "release, $w workers (timeout 60 s): $out $(cat err.txt)"
        expect_eq "$out" "20 300" "release, $w workers"
        stole=$(( stole + $(count stole err.txt) )); inlined=$(( inlined + $(count inlined err.txt) ))
    done
    out=$(RIG_WORKERS=$w RIG_SANITIZE=1 RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 120 ./race-debug 2>err.txt) || fail "sanitized debug, $w workers (timeout 120 s): $out $(cat err.txt)"
    expect_eq "$out" "20 300" "sanitized debug, $w workers"
    stole=$(( stole + $(count stole err.txt) )); inlined=$(( inlined + $(count inlined err.txt) ))
done
(( stole > 0 )) || fail "no fork was stolen"
(( inlined > 100000 )) || fail "only $inlined forks ran inline"
exit 0
