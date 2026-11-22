# tools/migrate-tov.py rewrites a program for "total or visible"
# (docs/design/datetime.md, 10.4), driven by `rig check`: a call that now
# fails gets `!`, or `catch panic` where its function cannot pass the
# failure on (printed as MANUAL); a `!` a constant maker no longer takes
# is dropped; the `checked_` names become the plain ones, but a `Time`'s,
# which is left for a person; `Instant.from_unix` becomes the maker of
# its unit; an `I128` reader where an `Int` is wanted is read through
# `Int(...)`; and a duration form the callee cannot fail for is made
# visibly first. The result runs, and a second run changes nothing.
source "$ROOT/test/cli/_lib.sh"

cat >prog.rig <<'EOF2'
use std.datetime
use std.time

fun next(d: datetime.Date) -> datetime.Date
  d.add(days: 1)

fun later(d: datetime.Date, n: Int) -> datetime.Date!
  d.checked_add(days: n)

fun took(t: time.Monotonic) -> Int
  t.elapsed().ns()

fun span(d: time.Duration) -> Int
  1

sub main()!
  d = datetime.Date.new(2026, 1, 31)
  print(next(d), later(d, 2)!, d.add(months: 1))
  i = datetime.Instant.from_unix(1_700_000_000)
  j = datetime.Instant.from_unix(ms: -1500)
  k = datetime.Instant.from_unix(ns: 7)
  h = datetime.Instant.from_unix(1.5)
  print(i, j, k, h, i.round(hours: 1))
  m = time.monotonic()
  print(took(m) >= 0, m.add(ms: 1) > m)
  n = took(m) + 1
  print(span(minutes: n), time.duration(ms: 250).times(2))
  t = datetime.Time.new(23, 0, 0)
  print(t.checked_add(time.duration(hours: 2)) catch t)
EOF2
python3 "$ROOT/tools/migrate-tov.py" --rig "$RIG" prog.rig >out.txt 2>&1 || fail "migrate: $(cat out.txt)"
expect_has "$(cat out.txt)" "MANUAL prog.rig:5: \`d.add(days: 1)\` cannot pass a failure on" "a panic left where the library had it"
expect_has "$(cat out.txt)" "MANUAL prog.rig:29: \`Time.checked_add\` is gone" "a time's checked_add left for a person"
grep -q '^  (d.add(days: 1) catch panic("d.add(days: 1) failed"))$' prog.rig || fail "the panic in the source: $(cat prog.rig)"
grep -q '^  d.add(days: n)!$' prog.rig || fail "checked_add renamed, and given its !: $(cat prog.rig)"
grep -q '^  Int(t.elapsed().ns())$' prog.rig || fail "the I128 read as an Int: $(cat prog.rig)"
grep -q '^  print(next(d), later(d, 2)!, d.add(months: 1)!)$' prog.rig || fail "add given !: $(cat prog.rig)"
grep -q '^  i = datetime.Instant.from_unix_s(1_700_000_000)$' prog.rig || fail "a constant maker without !: $(cat prog.rig)"
grep -q '^  j = datetime.Instant.from_unix_ms(-1500)$' prog.rig || fail "from_unix(ms:): $(cat prog.rig)"
grep -q '^  k = datetime.Instant.from_unix_ns(7)$' prog.rig || fail "from_unix(ns:): $(cat prog.rig)"
grep -q '^  h = datetime.Instant.from_unix_float(1.5)!$' prog.rig || fail "from_unix of a Float: $(cat prog.rig)"
grep -q 'span(time.duration(minutes: n)!)' prog.rig || fail "the form made visibly: $(cat prog.rig)"
grep -q 'time.duration(ms: 250).times(2)!' prog.rig || fail "Duration.times given !: $(cat prog.rig)"
# The time's checked_add, left for a person, is the one line it does not fix.
sed -i.bak 's/^  print(t.checked_add(time.duration(hours: 2)) catch t)$/  print(t.add(hours: 2))/' prog.rig
out=$("$RIG" run prog.rig 2>&1) || fail "prog.rig after: $out"
expect_eq "$out" "2026-02-01 2026-02-02 2026-02-28
2023-11-14T22:13:20Z 1969-12-31T23:59:58.5Z 1970-01-01T00:00:00.000000007Z 1970-01-01T00:00:01.5Z 2023-11-14T22:00:00Z
true true
1 500ms
01:00:00" "prog.rig runs"
cp prog.rig prog1.rig
python3 "$ROOT/tools/migrate-tov.py" --rig "$RIG" prog.rig >out2.txt 2>&1 || fail "second run: $(cat out2.txt)"
expect_has "$(cat out2.txt)" "0 rewritten" "a second run rewrites nothing"
cmp -s prog.rig prog1.rig || fail "a second run changed prog.rig"
