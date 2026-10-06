# `rig run` exits with the program's status only once the program has
# started: any failure before that prints `rig: the program did not run`
# and exits 125. The file RIG_RUN_STARTED names, which rig creates only
# once the program has started, is the positive evidence of a run that
# test/run and test/matrix.py require, so a program that never ran never
# passes (see also not_run_evidence.sh).
source "$ROOT/test/cli/_lib.sh"

printf 'sub main()\n  print("ran")\n' >ok.rig
printf 'fun main() -> Int\n  125\n' >own.rig
: >afile

# A store that cannot be made.
out=$(RIG_BUILD_STORE=$PWD/afile/store RIG_RUN_STARTED=$PWD/s1 "$RIG" run ok.rig 2>&1); expect_rc $? 125 "unusable store"
expect_has "$out" "rig: the program did not run" "unusable store"
[[ -e s1 ]] && fail "a program that did not run left its evidence"

# No Zig.
out=$(ZIG=$PWD/no-zig RIG_RUN_STARTED=$PWD/s2 rig run ok.rig 2>&1); expect_rc $? 125 "no Zig"
expect_has "$out" "rig: the program did not run" "no Zig"
[[ -e s2 ]] && fail "a program Zig could not build left its evidence"

# A program that exits 125 itself ran: no message, and its evidence.
out=$(RIG_RUN_STARTED=$PWD/s3 rig run own.rig 2>&1); expect_rc $? 125 "the program's own 125"
expect_eq "$out" "" "the program's own 125"
[[ -e s3 ]] || fail "a program that ran left no evidence"

# A store entry whose binaries are gone but whose manifests are not is
# rebuilt, not run from a binary that is not there.
store=$PWD/store
out=$(RIG_BUILD_STORE=$store "$RIG" run ok.rig 2>&1); expect_eq "$out" "ran" "first build"
entry=$(find "$store" -mindepth 1 -maxdepth 1 -type d ! -name '.*')
rm -rf "$entry/o"
out=$(RIG_BUILD_STORE=$store RIG_RUN_STARTED=$PWD/s4 "$RIG" run ok.rig 2>/dev/null); expect_eq "$out" "ran" "an entry without binaries"
[[ -e s4 ]] || fail "the rebuilt program left no evidence"

# Only what `rig run` and `rig test` build has the hook: a program `rig
# build` makes, or `rig emit` writes, never mentions the variable, and
# never creates the file.
"$RIG" build -o built ok.rig >/dev/null 2>&1 || fail "build ok.rig"
grep -q RIG_RUN_STARTED built && fail "a built program names RIG_RUN_STARTED"
expect_eq "$(RIG_RUN_STARTED=$PWD/s5 ./built)" "ran" "the built program"
[[ -e s5 ]] && fail "a built program created the RIG_RUN_STARTED file"
RIG_OUT_DIR=$PWD/emitted "$RIG" emit ok.rig >/dev/null 2>&1 || fail "emit ok.rig"
grep -rq -e RIG_RUN_STARTED -e "pub const __rig_run_started" emitted && fail "rig emit's package has the hook"
RIG_BUILD_STORE=$PWD/bstore "$RIG" build -o built2 ok.rig >/dev/null 2>&1 || fail "build ok.rig in a store"
grep -rq -e RIG_RUN_STARTED -e "pub const __rig_run_started" bstore && fail "rig build's package in the store has the hook"

# The suite and the matrix fail a program that never ran.
bad=$PWD/afile/store
o=$(RIG_BUILD_STORE=$bad RIG_TEST_OUT=$PWD/out "$ROOT/test/run" corpus/R11a-d1s examples/hello 2>&1); expect_rc $? 1 "test/run over an unusable store"
expect_has "$o" "FAIL   corpus/R11a-d1s — the program did not run" "a corpus program that did not run"
expect_has "$o" "FAIL   examples/hello — the program did not run" "an example that did not run"
o=$(RIG_BUILD_STORE=$bad python3 "$ROOT/test/matrix.py" -k int.print.place 2>&1); expect_rc $? 1 "matrix over an unusable store"
expect_has "$o" "the program did not run" "a matrix program that did not run"
exit 0
