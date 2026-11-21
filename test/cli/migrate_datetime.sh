# tools/migrate-datetime.py rewrites a program's std.time for
# `time.Monotonic` and `time.Duration`: `time.now()`, `time.Instant`, and
# the constants of nanoseconds are gone, and a clock gives a Duration.
# The program means what it meant and prints what it printed: a reading
# compared with a constant becomes a comparison of durations, and any
# other keeps its nanoseconds. A reading it takes for a clock's, and a
# constant kept as a number, are reported (CHECK); a function value of
# `time.since_start` is reported for a person (MANUAL).
source "$ROOT/test/cli/_lib.sh"

cat >old.rig <<'EOF'
use std.time
use std.time as clock

obj Row
  ns: Int
  check: Int

fun waited(start: time.Instant) -> Int
  start.elapsed()

fun timed() -> Row
  t = time.now()
  Row(ns: t.elapsed(), check: 1)

sub main()!
  start = time.now()
  deadline = start.add(ns: 3 * time.MS)
  time.sleep(ns: 2 * time.MS)!
  later = clock.now()
  took = later.since(start)
  print(took >= 2 * time.MS, took < 10 * time.SECOND, start.since(later) == -took)
  print(start.elapsed() >= 2 * time.MS, start.elapsed() < time.MINUTE, waited(start) >= took)
  time.sleep(ns: later.since(start))!
  a = time.since_start()
  print(a >= 0, timed().ns >= 0, time.now() >= deadline)
  print(time.NS, time.US, time.MS, time.SECOND, time.MINUTE)
  z = time.Instant.at(0)
  print(z.add(ms: 40).since(z), clock.Instant.at(ns: 7).since(z))
  f: fun() -> Int = time.since_start
  print(f() >= 0)
EOF
cat >new.rig <<'EOF'
use std.time
use std.time as clock

obj Row
  ns: Int
  check: Int

fun waited(start: time.Monotonic) -> Int
  start.elapsed().ns()

fun timed() -> Row
  t = time.monotonic()
  Row(ns: t.elapsed().ns(), check: 1)

sub main()!
  start = time.monotonic()
  deadline = start.add(ms: 3)
  time.sleep(ms: 2)!
  later = clock.monotonic()
  took = later.since(start).ns()
  print(took >= 2 * 1_000_000, took < 10 * 1_000_000_000, start.since(later).ns() == -took)
  print(start.elapsed() >= time.duration(ms: 2), start.elapsed() < time.duration(minutes: 1), waited(start) >= took)
  time.sleep(later.since(start))!
  a = time.since_start().ns()
  print(a >= 0, timed().ns >= 0, time.monotonic() >= deadline)
  print(1, 1_000, 1_000_000, 1_000_000_000, 60_000_000_000)
  z = time.Monotonic.at(0)
  print(z.add(ms: 40).since(z).ns(), clock.Monotonic.at(ns: 7).since(z).ns())
  f: fun() -> Int = time.since_start
  print(f() >= 0)
EOF
cat >doc.md <<'EOF'
`time.now()` read the monotonic clock.

```rig
use std.time

sub main()
  start = time.now()
  print(start.elapsed() < 5 * time.SECOND)
```
EOF
python3 "$ROOT/tools/migrate-datetime.py" old.rig doc.md >out.txt 2>&1 || fail "migrate: $(cat out.txt)"
expect_has "$(cat out.txt)" "old.rig: 26" "every form of old.rig rewritten"
expect_has "$(cat out.txt)" "CHECK old.rig:20: \`later.since(start)\` taken as a reading of the monotonic clock" "a reading it takes for a clock's"
expect_has "$(cat out.txt)" "CHECK old.rig:26: a constant of nanoseconds kept as a number" "a constant kept as a number"
expect_has "$(cat out.txt)" "MANUAL old.rig:29: \`time.since_start\` as a value gives a \`time.Duration\` now" "a function value it leaves"
diff old.rig new.rig >diff.txt || fail "old.rig migrated differs: $(cat diff.txt)"
expect_has "$(head -1 doc.md)" "time.now()" "prose left as it is"
grep -q '^  print(start.elapsed() < time.duration(5))$' doc.md || fail "the rig block not rewritten: $(cat doc.md)"
# The function value, left for a person, is the one line it does not fix.
sed -i.bak 's/^  f: fun() -> Int = time.since_start$/  f = || time.since_start().ns()/' old.rig
out=$("$RIG" run old.rig 2>&1) || fail "old.rig after: $out"
expect_eq "$out" "true true true
true true true
true true true
1 1000 1000000 1000000000 60000000000
40000000 7
true" "old.rig prints what it printed"
