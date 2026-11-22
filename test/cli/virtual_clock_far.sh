# A wait the scheduler clamps moves the virtual clock of a deterministic
# run (RIG_SEED) past 146 years; a reading of the monotonic clock then
# stays at 2^62 nanoseconds, the most a `time.Monotonic` holds
# (docs/design/datetime.md §5.7), and neither `time.monotonic()` nor
# `time.since_start()` panics. Run deterministically only: in real time
# the wait would never end.
source "$ROOT/test/cli/_lib.sh"

cat >far.rig <<'EOF2'
use std.time

fun k(n: Int) -> Int
  n

sub main()!
  time.sleep(hours: k(Int.max))!
  print("slept")
  time.sleep(seconds: 1)!
  m = time.monotonic()
  last = time.Monotonic.at(ns: 4_611_686_018_427_387_904)!
  print(m == last, time.monotonic().elapsed() == time.duration(0), time.since_start() <= last.since(time.Monotonic.at(0)!))
EOF2
out=$(RIG_SEED=1 $TIMEOUT_CMD 60 "$RIG" run far.rig 2>&1) || fail "far.rig: $out"
expect_eq "$out" "slept
true true true" "readings at 2^62 after a far wait"
