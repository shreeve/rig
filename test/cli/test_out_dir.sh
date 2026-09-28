# The suite deletes old output in its output directory, so it refuses a
# RIG_TEST_OUT that holds files it did not write, and marks a new or
# empty one as its own.
source "$ROOT/test/cli/_lib.sh"

mkdir shared
echo keep >shared/notes.txt
mkdir -p shared/behavior/mine
echo keep >shared/behavior/mine/data.txt
out=$(RIG_TEST_OUT="$PWD/shared" "$ROOT/test/run" known 2>&1); rc=$?
expect_rc "$rc" 2 "run in a directory holding other files"
expect_has "$out" "holds files this runner did not write" "refusal message"
[[ -f shared/notes.txt && -f shared/behavior/mine/data.txt ]] || fail "the run deleted files it did not write"

out=$(RIG_TEST_OUT="$PWD/fresh" "$ROOT/test/run" known 2>&1); rc=$?
expect_rc "$rc" 0 "run in a new directory: $out"
[[ -f fresh/.rig-test ]] || fail "a new output directory was not marked"
out=$(RIG_TEST_OUT="$PWD/fresh" "$ROOT/test/run" known 2>&1); rc=$?
expect_rc "$rc" 0 "second run in a marked directory: $out"
