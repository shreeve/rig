# `rig test` runs every `test` block of the program, in order, and
# reports each: `ok    test "name"`, or `FAIL  test "name": why`
# for a test that returns an error, gives `false`, leaks, or panics (a
# panic ends the run). The exit status is 1 when any test failed.
# builds: shared
source "$ROOT/test/cli/_lib.sh"

cat >util.rig <<'EOF'
pub fun double(n: Int) -> Int
  n * 2

test "double"
  print(double(21))
EOF
cat >main.rig <<'EOF'
use util

fun area(w: Int, h: Int) -> Int
  w * h

test "area"
  print(area(2, 3))

test "shared handles are released"
  v: List[*Cell[Int]] = List()
  (!v).push(*Cell(1))
  print(v.len)
EOF

out=$(rig test main.rig 2>&1); expect_rc $? 0 "passing tests"
expect_eq "$out" $'6\nok    test "area"\n1\nok    test "shared handles are released"\n2 passed, 0 failed' "report; the imported module's test does not run"

# A program with tests and no main is fine for `rig test`.
out=$(rig test util.rig 2>&1); expect_rc $? 0 "tests without main"
expect_has "$out" "1 passed, 0 failed" "tests without main"

cat >failing.rig <<'EOF'
obj Node
  next: *Cell[*Node?]

fun pick(xs: [3]Int, i: Int) -> Int
  xs[i]

error Bad
  oops

fun risky(n: Int) -> Int!
  return Bad.oops if n > 0
  n

test "passes"
  print("fine")

test "leaks a cycle"
  a = *Node(next: *Cell(none))
  !a.next.set(+a)

test "fails with an error"
  print(risky(0)!)
  print(risky(1)!)

test "panics"
  print(pick([1, 2, 3], 9))

test "never runs"
  print("unreachable")
EOF
RIG_NO_CRASH_REPORT=1 rig test failing.rig >out.txt 2>err.txt; rc=$?
expect_rc $rc 134 "a run a test panicked in"
expect_eq "$(cat out.txt)" $'fine\nok    test "passes"\nFAIL  test "leaks a cycle": memory leak\n0\nFAIL  test "fails with an error": Bad.oops\nFAIL  test "panics": panicked\n1 passed, 3 failed\nseed 1: `rig test --seed=1` runs these tests the same way again' "failing report"
expect_has "$(cat err.txt)" "memory leak detected: 2 allocations" "leak detail"
expect_has "$(cat err.txt)" "index out of bounds" "panic detail"

# With RIG_LEAK_TRACE=1 set, a test's leak comes with the trace of each
# allocation it left, shown after the summary.
cat >leak.rig <<'EOF'
obj Node
  next: *Cell[*Node?]

test "passes"
  true

test "leaks a cycle"
  a = *Node(next: *Cell(none))
  !a.next.set(+a)
EOF
rig test leak.rig >out.txt 2>err.txt; expect_rc $? 1 "a leaking test"
expect_has "$(cat err.txt)" "RIG_LEAK_TRACE=1 rig test" "hint names rig test"
RIG_LEAK_TRACE=1 rig test leak.rig >out.txt 2>err.txt; expect_rc $? 1 "a leaking test, traced"
expect_eq "$(cat out.txt)" $'ok    test "passes"\nFAIL  test "leaks a cycle": memory leak\n1 passed, 1 failed\nseed 1: `rig test --seed=1` runs these tests the same way again' "traced report"
expect_has "$(cat err.txt)" "error(SafeAllocator): leaked" "traced leak report"
expect_has "$(cat err.txt)" "__rig_main.zig:" "trace into the test"

# A test's value decides it: a `Bool` last line, or a `return`'s.
# The program extends SPEC.md's (Tests).
cat >bool.rig <<'EOF'
error Parse
  empty
  long

fun sum(xs: []Int) -> Int
  total = 0
  for x in xs
    total += x
  total

fun parse(s: ?String) -> Int!
  return Parse.empty if s.len == 0
  return Parse.long if s.len > 3
  s.len

test "sum adds the elements"
  sum([1, 2, 3]) == 6

test "a list grows and shrinks"
  xs: List[Int] = List()
  !xs.push(1)
  !xs.push(2)
  return false if xs.len != 2
  n = (!xs).pop() ?? -1
  n == 2 and xs.len == 1

test "parse reads text"
  parse("abc")! == 3

test "parse rejects empty text"
  _ = parse("") catch |e| return e == Parse.empty
  false

test "sum is wrong on purpose"
  sum([1, 2, 3]) == 7

test "prints and passes"
  print(sum([4, 5]))

test "make sure move works"
  s = String("a")
  t = <s
  t == "a"

test "an early return false"
  n = 3
  return false if n > 2  # too big
  print("not here")

test "no error comes"
  _ = parse("ab") catch |e| return e == Parse.empty
  false

test "another error comes"
  _ = parse("abcdef") catch |e| return e == Parse.empty
  false

test "a failing bang"
  parse("abcdef")! == 3
EOF
rig test bool.rig >out.txt 2>&1; rc=$?
expect_rc $rc 1 "a run a test gave false in"
expect_eq "$(cat out.txt)" $'ok    test "sum adds the elements"\nok    test "a list grows and shrinks"\nok    test "parse reads text"\nok    test "parse rejects empty text"\nFAIL  test "sum is wrong on purpose": sum([1, 2, 3]) == 7 is false\n9\nok    test "prints and passes"\nok    test "make sure move works"\nFAIL  test "an early return false": return false if n > 2\nFAIL  test "no error comes": reached false on line 52\nFAIL  test "another error comes": e == Parse.empty is false\nFAIL  test "a failing bang": Parse.long\n6 passed, 5 failed\nseed 1: `rig test --seed=1` runs these tests the same way again' "Bool report"

# A test that fails with fields shows them, and drops them before the
# next test's leak check.
cat >fields.rig <<'EOF'
error E
  bad(msg: String)

fun f(n: Int) -> Int!E
  return E.bad(msg: String("at")) if n > 0
  n

test "fails with fields"
  f(1)! == 1

test "passes after"
  f(0)! == 0
EOF
rig test fields.rig >out.txt 2>&1; rc=$?
expect_rc $rc 1 "a run a test failed with fields in"
expect_eq "$(cat out.txt)" $'FAIL  test "fails with fields": E.bad(msg: "at")\nok    test "passes after"\n1 passed, 1 failed\nseed 1: `rig test --seed=1` runs these tests the same way again' "a failure with fields"

cat >none.rig <<'EOF'
sub main()
  print("no tests here")
EOF
expect_eq "$(rig test none.rig 2>&1)" "0 passed, 0 failed" "no tests"
exit 0
