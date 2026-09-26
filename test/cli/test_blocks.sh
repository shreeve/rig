# `rig test` runs every `test` block of the program and its modules, in
# order, and reports each: `ok    test "name"`, or `FAIL  test "name": why`
# for a test that returns an error, leaks, or panics (a panic ends the
# run). The exit status is 1 when any test failed.
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
  v: Vec[*Cell[Int]] = Vec()
  (!v).push(*Cell(value: 1))
  print(v.len)
EOF

out=$("$RIG" test main.rig 2>&1); expect_rc $? 0 "passing tests"
expect_eq "$out" $'6\nok    test "area"\n1\nok    test "shared handles are released"\n42\nok    test "double" (util)\n3 passed, 0 failed' "report"

# A program with tests and no main is fine for `rig test`.
out=$("$RIG" test util.rig 2>&1); expect_rc $? 0 "tests without main"
expect_has "$out" "1 passed, 0 failed" "tests without main"

cat >failing.rig <<'EOF'
struct Node
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
  a = *Node(next: *Cell(value: none))
  a.next.set(+a)

test "fails with an error"
  print(risky(0)!)
  print(risky(1)!)

test "panics"
  print(pick([1, 2, 3], 9))

test "never runs"
  print("unreachable")
EOF
"$RIG" test failing.rig >out.txt 2>err.txt; rc=$?
[[ $rc -ne 0 ]] || fail "failing tests exited 0"
expect_eq "$(cat out.txt)" $'fine\nok    test "passes"\nFAIL  test "leaks a cycle": memory leak\n0\nFAIL  test "fails with an error": error.oops\nFAIL  test "panics": panicked' "failing report"
expect_has "$(cat err.txt)" "memory leak detected: 2 allocations" "leak detail"
expect_has "$(cat err.txt)" "index out of bounds" "panic detail"

cat >none.rig <<'EOF'
sub main()
  print("no tests here")
EOF
expect_eq "$("$RIG" test none.rig 2>&1)" "0 passed, 0 failed" "no tests"
exit 0
