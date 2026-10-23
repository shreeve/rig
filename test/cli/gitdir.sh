# tools/gitdir finds the repository of the Rig checkout it is in, never
# one that encloses a plain copy of Rig (a `git archive` snapshot with no
# .git of its own): tools/heavy keeps its lock there, and test/rig.rip
# and test/matrix.py their build store, so a run from a copy under
# another repository would neither queue with the worktrees' runs nor
# share their store. It takes the repository git finds only when that
# repository's top level holds rig.grammar and src/rig.zig; an explicit
# GIT_DIR names one instead; otherwise each tool stops with a message
# naming the fix. GIT_CEILING_DIRECTORIES keeps git from looking above
# this test's own directory.
source "$ROOT/test/cli/_lib.sh"

export GIT_CEILING_DIRECTORIES=$(pwd -P)
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR RIG_BUILD_STORE RIG_RESULTS_CACHE
fix="not inside a Rig checkout"
hint="run from a worktree, or set GIT_DIR=~/Data/Code/rig/.git"

# copy DIR: a plain copy of the parts of Rig that ask tools/gitdir.
copy() {
  mkdir -p "$1/tools" "$1/test" "$1/src"
  cp "$ROOT/tools/gitdir" "$ROOT/tools/heavy" "$1/tools/"
  cp "$ROOT/test/rig.rip" "$ROOT/test/matrix.py" "$1/test/"
  : >"$1/rig.grammar"; : >"$1/src/rig.zig"
}

# A copy with no repository above it.
copy plain
out=$(plain/tools/heavy echo ran 2>&1); expect_rc $? 2 "heavy in a plain copy"
expect_has "$out" "tools/heavy: $fix" "heavy in a plain copy"
expect_has "$out" "$hint" "heavy in a plain copy"
out=$(cd plain && python3 test/matrix.py 2>&1); expect_rc $? 2 "matrix.py in a plain copy"
expect_has "$out" "test/matrix.py: $fix" "matrix.py in a plain copy"
if command -v swarm >/dev/null; then
  out=$(cd plain && "$TIMEOUT_CMD" 60 swarm test/rig.rip unit -q 2>&1); expect_rc $? 2 "rig.rip in a plain copy"
  expect_has "$out" "test/rig.rip: $fix" "rig.rip in a plain copy"
fi

# A copy inside a repository that is not Rig's: refused, and nothing is
# left in that repository.
mkdir outer && git -C outer init -q || fail "git init"
copy outer/copy
out=$(outer/copy/tools/heavy echo ran 2>&1); expect_rc $? 2 "heavy in a copy inside another repository"
expect_has "$out" "$fix" "heavy in a copy inside another repository"
expect_has "$out" "which is in $(cd outer && pwd -P)" "heavy names the enclosing repository"
[[ -z $(ls outer/.git | grep rig-) ]] || fail "heavy left its lock in the enclosing repository"

# A repository whose top level is Rig's: its own git directory.
copy rig
git -C rig init -q || fail "git init"
out=$(rig/tools/gitdir 2>&1); expect_eq "$out" "$(cd rig/.git && pwd -P)" "gitdir in Rig's repository"
out=$(rig/tools/heavy echo ran 2>&1); expect_eq "$out" "ran" "heavy in Rig's repository"
[[ -d rig/.git/rig-heavy.lock.q ]] || fail "heavy's queue is not in Rig's repository"

# An explicit GIT_DIR, relative or not, names the repository from a copy.
out=$(GIT_DIR=rig/.git plain/tools/gitdir 2>&1); expect_eq "$out" "$(cd rig/.git && pwd -P)" "GIT_DIR from a plain copy"
out=$(GIT_DIR=$PWD/rig/.git plain/tools/heavy echo ran 2>&1); expect_eq "$out" "ran" "heavy with GIT_DIR"
out=$(GIT_DIR=nowhere plain/tools/heavy echo ran 2>&1); expect_rc $? 2 "heavy with a GIT_DIR that is no repository"
expect_has "$out" "tools/heavy: GIT_DIR=nowhere is not a git directory" "heavy with a GIT_DIR that is no repository"
exit 0
