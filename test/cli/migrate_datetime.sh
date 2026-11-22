# tools/migrate-datetime.py rewrites a program's std.time for
# `time.Monotonic` and `time.Duration`: `time.now()`, `time.Instant`, and
# the constants of nanoseconds are gone, and a clock gives a Duration.
# The program means what it meant and prints what it printed: a reading
# compared with a constant becomes a comparison of durations, and any
# other keeps its nanoseconds. A reading it takes for a clock's, and a
# constant kept as a number, are reported (CHECK); a function value of
# `time.since_start` is reported for a person (MANUAL). `time.unix_ns()`
# becomes std.datetime's wall clock, with `use std.datetime` added in the
# order of the `use` lines, and a `use std.time` nothing names dropped.
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
# A second run changes nothing: what it migrated names no removed form.
cp doc.md doc1.md
python3 "$ROOT/tools/migrate-datetime.py" old.rig doc.md >out2.txt 2>&1 || fail "second run: $(cat out2.txt)"
expect_has "$(cat out2.txt)" "0 rewritten" "a second run rewrites nothing"
diff old.rig new.rig >diff.txt || fail "a second run changed old.rig: $(cat diff.txt)"
cmp -s doc.md doc1.md || fail "a second run changed doc.md"
expect_has "$(head -1 doc.md)" "time.now()" "prose left as it is"
grep -q '^  print(start.elapsed() < time.duration(5))$' doc.md || fail "the rig block not rewritten: $(cat doc.md)"
# The function value, left for a person, is the one line it does not fix.
sed -i.bak 's/^  f: fun() -> Int = time.since_start$/  f = || time.since_start().ns()/' old.rig
# Total or visible came after, and tools/migrate-tov.py, run next as
# docs/MIGRATING-0.3.md says, gives each call that now fails its `!`.
python3 "$ROOT/tools/migrate-tov.py" --rig "$RIG" old.rig >tov.txt 2>&1 || fail "migrate-tov: $(cat tov.txt)"
expect_has "$(cat tov.txt)" "MANUAL old.rig:22" "an Int compared with an I128, left for a person"
sed -i.bak 's/waited(start) >= took)$/waited(start) >= Int(took))/' old.rig
out=$("$RIG" run old.rig 2>&1) || fail "old.rig after: $out"
expect_eq "$out" "true true true
true true true
true true true
1 1000 1000000 1000000000 60000000000
40000000 7
true" "old.rig prints what it printed"

# The wall clock is std.datetime's: in a program, where `use std.time`
# is left with nothing to name and goes; in a test file, whose case
# reads the file's `use std.time`; and in a Markdown block that still
# times with std.time, which keeps it.
cat >wall.rig <<'EOF'
use std.file
use std.time

fun clock() -> Int
  time.unix_ns()

sub main()
  f: fun() -> Int = time.unix_ns
  print(clock() / 1_000_000_000 > 1_700_000_000, f() > 0)
EOF
cat >wall.rig.test <<'EOF'
use std.math
use std.time

test "the wall clock", "true"
  print(time.unix_ns() > 0)
EOF
cat >wall.md <<'EOF'
```rig
use std.time

sub main()
  start = time.monotonic()
  print(time.unix_ns() > 0, start.elapsed() >= time.duration(0))
```
EOF
python3 "$ROOT/tools/migrate-datetime.py" wall.rig wall.rig.test wall.md >out3.txt 2>&1 || fail "migrate: $(cat out3.txt)"
expect_has "$(cat out3.txt)" "wall.rig:5: time.unix_ns() -> datetime.now().unix().ns()" "the reading rewritten"
expect_has "$(cat out3.txt)" "MANUAL wall.rig:8: \`time.unix_ns\` as a value is gone" "the function value left for a person"
expect_has "$(cat out3.txt)" "3 rewritten" "each reading rewritten"
expect_eq "$(head -3 wall.rig)" "use std.datetime
use std.file
use std.time" "use std.datetime added, use std.time kept for the value it names"
expect_eq "$(head -3 wall.rig.test)" "use std.datetime
use std.math
use std.time" "the test file's header gains use std.datetime"
grep -q '^  print(datetime.now().unix().ns() > 0)$' wall.rig.test || fail "the case not rewritten: $(cat wall.rig.test)"
expect_eq "$(sed -n 2,3p wall.md)" "use std.datetime
use std.time" "the block keeps use std.time, which it times with"
sed -i.bak 's/^  f: fun() -> Int = time.unix_ns$/  f = || datetime.now().unix().ns()/' wall.rig
python3 "$ROOT/tools/migrate-datetime.py" wall.rig >out4.txt 2>&1 || fail "second run: $(cat out4.txt)"
expect_has "$(cat out4.txt)" "0 rewritten" "a second run rewrites nothing"
cat >only.rig <<'EOF'
use std.os
use std.time

sub main()
  print(time.unix_ns() > 0)
EOF
python3 "$ROOT/tools/migrate-datetime.py" only.rig >out5.txt 2>&1 || fail "migrate only.rig: $(cat out5.txt)"
expect_eq "$(head -2 only.rig)" "use std.datetime
use std.os" "use std.time, naming nothing now, dropped"
out=$("$RIG" run only.rig 2>&1) || fail "only.rig after: $out"
expect_eq "$out" "true" "only.rig prints what it printed"
python3 "$ROOT/tools/migrate-tov.py" --rig "$RIG" wall.rig >tov-wall.rig.txt 2>&1 || fail "migrate-tov: $(cat tov-wall.rig.txt)"
out=$("$RIG" run wall.rig 2>&1) || fail "wall.rig after: $out"
expect_eq "$out" "true true" "wall.rig prints what it printed"
# A file that names std.datetime by another name reads the wall clock
# by it; a `use std.time as t` that names nothing any more goes too.
cat >alias.rig <<'EOF'
use std.datetime as dt
use std.time as t

sub main()
  print(t.unix_ns() > 0, dt.Instant.from_unix(0))
EOF
python3 "$ROOT/tools/migrate-datetime.py" alias.rig >out6.txt 2>&1 || fail "migrate alias.rig: $(cat out6.txt)"
grep -q '^  print(dt.now().unix().ns() > 0, dt.Instant.from_unix(0))$' alias.rig || fail "the alias not used: $(cat alias.rig)"
expect_eq "$(head -1 alias.rig)" "use std.datetime as dt" "use std.datetime as dt kept"
grep -q 'use std.time' alias.rig && fail "use std.time as t, naming nothing now, kept: $(cat alias.rig)"
python3 "$ROOT/tools/migrate-tov.py" --rig "$RIG" alias.rig >tov-alias.rig.txt 2>&1 || fail "migrate-tov: $(cat tov-alias.rig.txt)"
out=$("$RIG" run alias.rig 2>&1) || fail "alias.rig after: $out"
expect_eq "$out" "true 1970-01-01T00:00:00Z" "alias.rig prints what it printed"
