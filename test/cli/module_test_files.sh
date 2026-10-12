# A directory module's files whose names end in `_test.rig` belong to it
# only in a build for `rig test`: they see its private names, and `rig
# run` and `rig check` leave them out.
source "$ROOT/test/cli/_lib.sh"

mkdir -p p/m
printf 'use m\n\nsub main()\n  print(m.twice(2))\n' >p/main.rig
printf 'pub fun twice(n: Int) -> Int\n  helper(n) * 2\n\nfun helper(n: Int) -> Int\n  n\n' >p/m/a.rig
printf 'test "a private helper"\n  print(helper(3))\n' >p/m/a_test.rig
out=$(rig test p/main.rig 2>&1); expect_rc $? 0 "rig test: $out"
expect_has "$out" 'ok    test "a private helper" (m)' "a test file's test runs"
expect_has "$out" '1 passed, 0 failed' "a test file's test runs"
out=$(rig run p/main.rig 2>&1); expect_rc $? 0 "rig run: $out"
expect_eq "$out" "4" "rig run"

# Left out of `rig run` and `rig check`: an error in a test file is
# reported by `rig test` only, and a name a test file declares is not
# the module's elsewhere.
printf 'fun broken() -> Int\n  nope\n' >p/m/b_test.rig
out=$("$RIG" check p/main.rig 2>&1); expect_rc $? 0 "rig check leaves test files out: $out"
out=$("$RIG" test p/main.rig 2>&1); expect_rc $? 1 "rig test reads test files"
expect_has "$out" "p/m/b_test.rig:2:3: error: use of unbound name \`nope\`" "rig test reads test files"
rm p/m/b_test.rig
printf 'pub fun only_in_tests() -> Int\n  1\n' >p/m/c_test.rig
printf 'use m\n\nsub main()\n  print(m.only_in_tests())\n' >p/uses.rig
out=$("$RIG" check p/uses.rig 2>&1); expect_rc $? 1 "a test file's name outside tests"
expect_has "$out" "only_in_tests" "a test file's name outside tests"
