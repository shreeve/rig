# tools/migrate-options.py names each option a call gives by position, as
# `rig check`'s own error says to, and gives `datetime.Time.new` its
# second: in a program, in each case of a test file, and in each ```rig
# block of a Markdown file, leaving a `pending` block and the prose as
# they are. The name goes before the whole argument, outside its
# parentheses, and what it cannot rewrite it names (MANUAL). The program
# it writes runs and prints what it printed, and a second run changes
# nothing.
source "$ROOT/test/cli/_lib.sh"

cat >prog.rig <<'EOF'
use std.datetime
use std.text

fun connect(host: ?String, port: Int, timeout: Int = 30, retry: Bool = true) -> Int
  port + timeout + (1 if retry else 0)

sub repeat(times: Int = 1, f: ?sub(Int))
  for i in 0..times
    f(i)

sub main()!
  print(connect("db", 5432, 5), connect("db", 5432, 1, false))
  print(text.parse_int("ff", 16)!, text.format_int(255, 2))
  t = datetime.Time.new(8, 30)
  u = datetime.Time.new(hour: 8, minute: 30)
  dt = datetime.DateTime.new(2026, 11, 17, 8, 30)
  print(t, u, dt.add(90), datetime.Time.new(8, 7, 3, 500))
  repeat(|i| print("once", i))
EOF
cat >want.rig <<'EOF'
use std.datetime
use std.text

fun connect(host: ?String, port: Int, timeout: Int = 30, retry: Bool = true) -> Int
  port + timeout + (1 if retry else 0)

sub repeat(times: Int = 1, f: ?sub(Int))
  for i in 0..times
    f(i)

sub main()!
  print(connect("db", 5432, timeout: 5), connect("db", 5432, timeout: 1, retry: false))
  print(text.parse_int("ff", base: 16)!, text.format_int(255, base: 2))
  t = datetime.Time.new(8, 30, 0)
  u = datetime.Time.new(hour: 8, minute: 30, second: 0)
  dt = datetime.DateTime.new(2026, 11, 17, hour: 8, minute: 30)
  print(t, u, dt.add(duration: 90), datetime.Time.new(8, 7, 3, ns: 500))
  repeat(|i| print("once", i))
EOF
cat >cases.rig.test <<'EOF'
use std.text

test "parsed", "255"
  text.parse_int("ff", 16)!

fail "missing", "has no parameter `width`"
  print(text.format_int(5, 2, width: 3))
EOF
cat >doc.md <<'EOF'
`text.parse_int("ff", 16)` in prose is left for a person.

```rig
use std.text

sub main()!
  print(text.parse_int("ff", 16)!)
```

```rig pending
use std.text

sub main()!
  print(text.parse_int("ff", 16)!)
```
EOF
python3 "$ROOT/tools/migrate-options.py" --rig "$RIG" prog.rig cases.rig.test doc.md >out.txt 2>&1 || fail "migrate: $(cat out.txt)"
expect_has "$(cat out.txt)" "prog.rig: 11" "the program's eleven arguments named or added"
expect_has "$(cat out.txt)" "cases.rig.test: 2" "the test file's two"
expect_has "$(cat out.txt)" "doc.md: 1" "the rig block's one, the pending block left"
expect_has "$(cat out.txt)" "14 rewritten" "fourteen in all"
diff prog.rig want.rig >diff.txt || fail "prog.rig migrated differs: $(cat diff.txt)"
expect_eq "$(sed -n 4p cases.rig.test)" "  text.parse_int(\"ff\", base: 16)!" "the test case's call"
expect_eq "$(sed -n 7p cases.rig.test)" "  print(text.format_int(5, base: 2, width: 3))" "the fail case's call"
expect_eq "$(head -1 doc.md)" "\`text.parse_int(\"ff\", 16)\` in prose is left for a person." "prose left"
expect_eq "$(sed -n 7p doc.md)" "  print(text.parse_int(\"ff\", base: 16)!)" "the block's call"
expect_eq "$(sed -n 14p doc.md)" "  print(text.parse_int(\"ff\", 16)!)" "the pending block left"
# Total or visible came after, and tools/migrate-tov.py, run next as
# docs/MIGRATING-0.3.md says, gives each call that now fails its `!`.
python3 "$ROOT/tools/migrate-tov.py" --rig "$RIG" prog.rig >tov.txt 2>&1 || fail "migrate-tov: $(cat tov.txt)"
out=$("$RIG" run prog.rig 2>&1) || fail "prog.rig after: $out"
expect_eq "$out" "5438 5433
255 11111111
08:30:00 08:30:00 2026-11-17T08:31:30 08:07:03.0000005
once 0" "prog.rig prints what it means"
# A second run changes nothing.
cp prog.rig prog1.rig; cp cases.rig.test cases1.rig.test; cp doc.md doc1.md
python3 "$ROOT/tools/migrate-options.py" --rig "$RIG" prog.rig cases.rig.test doc.md >out2.txt 2>&1 || fail "second run: $(cat out2.txt)"
expect_has "$(cat out2.txt)" "0 rewritten" "a second run rewrites nothing"
cmp -s prog.rig prog1.rig || fail "a second run changed prog.rig"
cmp -s cases.rig.test cases1.rig.test || fail "a second run changed cases.rig.test"
cmp -s doc.md doc1.md || fail "a second run changed doc.md"
# The name goes outside an argument's parentheses; a positional argument
# left after the option it named is still refused, and named for a person.
cat >more.rig <<'EOF'
fun scaled(n: Int, by: Int = 10) -> Int
  n * by

sub each(n: Int, step: Int = 1, f: ?sub(Int))
  i = 0
  while i < n
    f(i)
    i += step

sub show(i: Int)
  print(i)

sub main()
  print(scaled(1, (2)))
  each(3, 2, show)
EOF
python3 "$ROOT/tools/migrate-options.py" --rig "$RIG" more.rig >out3.txt 2>&1 || fail "migrate more.rig: $(cat out3.txt)"
expect_eq "$(sed -n 14p more.rig)" "  print(scaled(1, by: (2)))" "the name outside the parentheses"
expect_eq "$(sed -n 15p more.rig)" "  each(3, step: 2, show)" "the option named"
expect_has "$(cat out3.txt)" "MANUAL more.rig:15: still refused: positional arguments must come before keyword arguments" "the argument after it named for a person"
