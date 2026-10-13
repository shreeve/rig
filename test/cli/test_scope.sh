# `rig test X` runs the tests of X itself, as `go test pkg` does: the
# `test` blocks of the root file, or, for a directory module, its files
# and its `*_test.rig` files. The tests of the modules X imports, a
# directory module, a file module, or std, are not run, and a directory
# module's `*_test.rig` files are not even read when it is only imported.
source "$ROOT/test/cli/_lib.sh"

mkdir -p p/m p/n
# `m` is a directory module whose tests fail, inline and in a test file;
# `f` is a file module whose inline test fails.
printf 'error Bad\n  oops\n\nfun boom() -> Int!\n  return Bad.oops if 1 > 0\n  1\n\npub fun twice(n: Int) -> Int\n  n * 2\n\ntest "m inline"\n  print(boom()!)\n' >p/m/a.rig
printf 'test "m file"\n  print(boom()!)\n' >p/m/a_test.rig
printf 'error Bad\n  oops\n\nfun boom() -> Int!\n  return Bad.oops if 1 > 0\n  1\n\npub fun one() -> Int\n  1\n\ntest "f inline"\n  print(boom()!)\n' >p/f.rig
printf 'use m\nuse f\n\nsub main()\n  print(m.twice(f.one()))\n\ntest "root own"\n  print(m.twice(2))\n' >p/main.rig

# A program's own tests only.
out=$(rig test p/main.rig 2>&1); expect_rc $? 0 "program tests: $out"
expect_has "$out" 'ok    test "root own"' "the program's test runs"
expect_has "$out" '1 passed, 0 failed' "only the program's test runs"
case "$out" in *"m inline"* | *"m file"* | *"f inline"*) fail "an imported module's tests ran: $out" ;; esac

# The directory module itself: its files and its test files.
out=$(rig test p/m 2>&1); expect_rc $? 1 "directory module tests"
expect_has "$out" 'FAIL  test "m inline"' "a directory module's inline test runs"
expect_has "$out" 'FAIL  test "m file"' "a directory module's test file runs"
expect_has "$out" '0 passed, 2 failed' "a directory module's tests"

# A directory module that imports a file module runs its own tests, not
# the file module's.
printf 'use f\n\npub fun uno() -> Int\n  f.one()\n\ntest "n inline"\n  print(uno())\n' >p/n/a.rig
printf 'test "n file"\n  print(uno())\n' >p/n/a_test.rig
out=$(rig test p/n 2>&1); expect_rc $? 0 "directory module with imports: $out"
expect_has "$out" '2 passed, 0 failed' "a directory module's tests only"
case "$out" in *"f inline"*) fail "an imported file module's test ran: $out" ;; esac

# `rig check --tests` agrees: an error in an imported module's test file
# is not seen from the program, and is seen from the module itself.
printf 'test "typed"\n  n: Int = "text"\n  print(n)\n' >p/m/b_test.rig
out=$("$RIG" check --tests p/main.rig 2>&1); expect_rc $? 0 "check --tests of the program: $out"
out=$("$RIG" test p/main.rig 2>&1); expect_rc $? 0 "test of the program: $out"
out=$("$RIG" check --tests p/m 2>&1); expect_rc $? 1 "check --tests of the module"
expect_has "$out" "p/m/b_test.rig:2:12: error:" "check --tests of the module reads its test files"
out=$("$RIG" test p/m 2>&1); expect_rc $? 1 "test of the module"
expect_has "$out" "p/m/b_test.rig:2:12: error:" "rig test of the module reads its test files"
out=$("$RIG" check p/m 2>&1); expect_rc $? 0 "check of the module leaves test files out: $out"
