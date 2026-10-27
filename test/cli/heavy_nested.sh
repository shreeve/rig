# tools/heavy under a holder of the same lock runs its command at once:
# `tools/heavy tools/baseline` asks for the lock again inside, and would
# wait on itself. A repository of its own keeps the test off the real
# lock other runs hold.
# timeout: 60
source "$ROOT/test/cli/_lib.sh"

git init -q repo || fail "git init"
export GIT_DIR=$PWD/repo/.git
unset RIG_HEAVY_HELD
out=$(timeout 30 "$ROOT/tools/heavy" "$ROOT/tools/heavy" "$ROOT/tools/heavy" echo nested 2>&1); rc=$?
expect_rc $rc 0 "nested tools/heavy"
expect_eq "$out" "nested" "nested tools/heavy"
[[ ! -d $GIT_DIR/rig-heavy.lock ]] || fail "the lock outlived its holder"
exit 0
