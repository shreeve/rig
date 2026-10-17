# A run that selects no test program (only a whole-program check, here
# style) starts no worker: GNU xargs, as Linux has it, runs its command
# once on empty input unless told not to (-r), and a worker with no test
# fails on its unset arguments.
source "$ROOT/test/cli/_lib.sh"

out=$(RIG_TEST_OUT=$PWD/out "$ROOT/test/run" style 2>&1); rc=$?
expect_rc $rc 0 "a run of style alone"
expect_has "$out" "running 0 tests" "the count of test programs"
grep -qF "unbound variable" <<<"$out" && fail "a run with no test program: $out"
exit 0
