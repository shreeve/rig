#!/usr/bin/env bash
# timeout: 120
# Where preemption by signal is built, the monitor parks while no signal
# could help: two tasks that compute 400 ms each, with nothing else
# waiting and no timer or descriptor held, are looked at far fewer times
# than once a millisecond (`RIG_SCHED_STATS=1`'s "rig: monitor: looked
# N"). A task one of them makes as it computes wakes the parked monitor,
# which stops its maker, so it starts within milliseconds, not at the
# end of a parked sleep or of its maker's computation. Where preemption
# is not built, nothing runs.
source "$ROOT/test/cli/_lib.sh"
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64 | Darwin/arm64) ;;
    *) exit 0 ;;
esac

cat > park.rig <<'RIG'
use std.time

# Computes in the program's own code, where a signal stops it, and reads
# the clock once in 100,000 turns.
fun spin(ms: Int) -> Int
  t = time.now()
  n = 0
  while t.elapsed() < ms * 1000000
    for i in 0..100000
      n = (n + i * 7) % 1000003
  n

fun started() -> Int
  time.since_start()

fun maker() -> Int
  _ = spin(100)
  made = time.since_start()
  q = started()&
  _ = spin(300)
  (>q - made) / 1000000

sub main()
  a = spin(400)&
  b = maker()&
  _ = >a
  print(>b)
RIG
"$RIG" build --release=fast -o park park.rig >build.txt 2>&1 || fail "build park.rig: $(cat build.txt)"
for i in 1 2 3; do
    out=$(RIG_SCHED_STATS=1 RIG_WORKERS=2 "$TIMEOUT_CMD" 60 ./park 2>err.txt) || fail "park, run $i (timeout 60 s): $out $(cat err.txt)"
    line=$(grep '^rig: monitor: ' err.txt) || fail "no monitor line: $(cat err.txt)"
    looks=$(sed -n 's/^rig: monitor: looked \([0-9]*\), parked \([0-9]*\), woken \([0-9]*\)$/\1/p' err.txt)
    woken=$(sed -n 's/^rig: monitor: looked \([0-9]*\), parked \([0-9]*\), woken \([0-9]*\)$/\3/p' err.txt)
    [[ -n "$looks" && -n "$woken" ]] || fail "monitor line: $line"
    # 400 ms at one look a millisecond would be 400 looks.
    (( looks < 150 )) || fail "run $i: the monitor looked $looks times in 400 ms: $line"
    (( woken >= 1 )) || fail "run $i: the task made while the monitor was parked did not wake it: $line"
    # Waiting for its maker's 300 ms would print 300.
    (( out < 50 )) || fail "run $i: the task made behind a computation started after $out ms: $line"
done
exit 0
