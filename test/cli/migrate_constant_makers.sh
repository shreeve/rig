# tools/migrate-constant-makers.py drops the `!` from a call of
# std.datetime's `Date.new`, `Time.new`, or `DateTime.new` whose arguments
# are integer literals forming a real date or time, which Rig checks as it
# compiles (SPEC §13). It reaches the makers only through a name `use
# std.datetime` binds, its own or an `as` name, or a `type` alias of one
# of the three types: a program's own `Time.new` is left as it is, and so
# is text in a string. A test file's `fail` cases, which show errors, are
# left as they are, and so is a Markdown file's prose; a literal call the
# maker refuses, with a `!` or a `catch`, is named for a person (MANUAL).
# A second run changes nothing.
source "$ROOT/test/cli/_lib.sh"

cat >prog.rig <<'EOF'
use std.datetime as dt

type D = dt.Date

error TimeError
  range

obj Time
  h: Int

  pub fun new(h: Int, m: Int) -> Time!
    return TimeError.range if h > 23
    Time(h: h)

sub main()!
  t = Time.new(8, 30)!
  a = dt.Date.new(2026, 1, 31)!
  b = D.new(2026, 2, 28)!.add(days: 1)
  c = dt.Time.new(hour: 8, minute: 30, second: 0)!
  print(t.h, a, b, c)
  print("dt.Date.new(2026, 1, 31)!", `{a} dt.Time.new(1, 2)!`)
EOF
cat >want.rig <<'EOF'
use std.datetime as dt

type D = dt.Date

error TimeError
  range

obj Time
  h: Int

  pub fun new(h: Int, m: Int) -> Time!
    return TimeError.range if h > 23
    Time(h: h)

sub main()!
  t = Time.new(8, 30)!
  a = dt.Date.new(2026, 1, 31)
  b = D.new(2026, 2, 28).add(days: 1)
  c = dt.Time.new(hour: 8, minute: 30, second: 0)
  print(t.h, a, b, c)
  print("dt.Date.new(2026, 1, 31)!", `{a} dt.Time.new(1, 2)!`)
EOF
cat >cases.rig.test <<'EOF'
use std.datetime

test "made", "2026-01-31"
  print(datetime.Date.new(2026, 1, 31)!)

fail "shown refused", "`!` needs a fallible operand", errors: 1
  d = datetime.Date.new(2026, 1, 31)!
  print(d)

test "refused at run time", "range"
  d = datetime.Date.new(2023, 2, 29) catch none
  print("range" if d == none else "made")
EOF
cat >doc.md <<'EOF'
`datetime.Date.new(2026, 1, 31)!` in prose is left for a person.

```rig
use std.datetime

sub main()
  print(datetime.Date.new(2026, 1, 31)!)
```
EOF
cp cases.rig.test cases0.rig.test
python3 "$ROOT/tools/migrate-constant-makers.py" prog.rig cases.rig.test doc.md >out.txt 2>&1 || fail "migrate: $(cat out.txt)"
expect_has "$(cat out.txt)" "prog.rig: 3" "the three calls of std's makers rewritten"
expect_has "$(cat out.txt)" "cases.rig.test: 1" "the test case rewritten, the fail case left"
expect_has "$(cat out.txt)" "doc.md: 1" "the rig block rewritten"
expect_has "$(cat out.txt)" "MANUAL cases.rig.test:11: day 29 is refused" "a refused literal call named"
expect_has "$(cat out.txt)" "5 rewritten" "five calls in all"
diff prog.rig want.rig >diff.txt || fail "prog.rig migrated differs: $(cat diff.txt)"
expect_eq "$(sed -n 4p cases.rig.test)" "  print(datetime.Date.new(2026, 1, 31))" "the test case's call"
expect_eq "$(sed -n 7p cases.rig.test)" "  d = datetime.Date.new(2026, 1, 31)!" "the fail case left as it is"
expect_eq "$(head -1 doc.md)" "\`datetime.Date.new(2026, 1, 31)!\` in prose is left for a person." "prose left"
expect_eq "$(sed -n 7p doc.md)" "  print(datetime.Date.new(2026, 1, 31))" "the block's call"
out=$("$RIG" run prog.rig 2>&1) || fail "prog.rig after: $out"
expect_eq "$out" "8 2026-01-31 2026-03-01 08:30:00
dt.Date.new(2026, 1, 31)! 2026-01-31 dt.Time.new(1, 2)!" "prog.rig prints what it printed"
# A second run changes nothing.
cp prog.rig prog1.rig; cp cases.rig.test cases1.rig.test; cp doc.md doc1.md
python3 "$ROOT/tools/migrate-constant-makers.py" prog.rig cases.rig.test doc.md >out2.txt 2>&1 || fail "second run: $(cat out2.txt)"
expect_has "$(cat out2.txt)" "0 rewritten" "a second run rewrites nothing"
cmp -s prog.rig prog1.rig || fail "a second run changed prog.rig"
cmp -s cases.rig.test cases1.rig.test || fail "a second run changed cases.rig.test"
cmp -s doc.md doc1.md || fail "a second run changed doc.md"
