#!/usr/bin/env bash
# timeout: 120
# Where preemption by signal is built, the monitor parks while no signal
# could help: two tasks that compute 400 ms each, with nothing else
# waiting and no timer or descriptor held, are looked at far fewer times
# than once a millisecond (`RIG_SCHED_STATS=1`'s "rig: monitor: looked
# N"). A task one of them makes as it computes wakes the parked monitor,
# which stops its maker, so it starts within milliseconds, not at the
# end of a parked sleep or of its maker's computation. The woken monitor
# looks a millisecond later, as one that never parks would at the
# latest: a task its maker waits for a fraction of a millisecond after
# making it is gone by then, so its maker is not stopped to hand it on
# ("preempted N"). Where preemption is not built, nothing runs.
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

cat > fork.rig <<'RIG'
use std.time

# Computes in the program's own code, where a signal stops it, and reads
# the clock once in 100,000 turns. Its caller uses what it gives, so the
# turns stay.
fun spin(ms: Int) -> Int
  t = time.now()
  n = 0
  while t.elapsed() < ms * 1000000
    for i in 0..100000
      n = (n + i * 7) % 1000003
  n

fun turns(k: Int) -> Int
  n = 0
  for i in 0..k
    n = (n + i * 7) % 1000003
  n

fun leaf(i: Int) -> Int
  i

# Makes a task, computes 60,000 turns (about 0.2 ms), and waits for it,
# 100 times, 6 ms apart, long enough for the monitor to park between.
fun maker() -> Int
  sum = 0
  for i in 0..100
    sum += spin(6) % 2
    q = leaf(i)&
    sum += turns(60000 + i) % 2
    sum += >q
  sum

sub main()
  m = maker()&
  print(>m)
RIG
"$RIG" build --release=fast -o fork fork.rig >build.txt 2>&1 || fail "build fork.rig: $(cat build.txt)"
for i in 1 2 3; do
    out=$(RIG_SCHED_STATS=1 RIG_WORKERS=2 "$TIMEOUT_CMD" 60 ./fork 2>err.txt) || fail "fork, run $i (timeout 60 s): $out $(cat err.txt)"
    # Stopped to run its task itself, or to leave it to the idle worker.
    stops=$(sed -n 's/^rig: worker [01]: .* stole \([0-9]*\), .* preempted \([0-9]*\),.*$/\1 \2/p' err.txt | awk '{n += $1 + $2} END {print n}')
    woken=$(sed -n 's/^rig: monitor: looked \([0-9]*\), parked \([0-9]*\), woken \([0-9]*\)$/\3/p' err.txt)
    [[ -n "$stops" && -n "$woken" ]] || fail "fork, run $i: no counts: $(cat err.txt)"
    # A monitor that looked as it woke would stop the maker for each task.
    (( woken >= 50 )) || fail "fork, run $i: 100 tasks made 6 ms apart woke the monitor $woken times: $(cat err.txt)"
    (( stops < 40 )) || fail "fork, run $i: the maker was stopped or its task stolen $stops times for 100 tasks it waited for about 0.2 ms after making: $(cat err.txt)"
done
exit 0
