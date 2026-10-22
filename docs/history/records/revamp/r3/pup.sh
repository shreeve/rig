#!/bin/bash
# pup.sh <branch> <cmd...>: run <cmd> on pup (Linux x86_64) against a
# local branch, streaming the output; exits with <cmd>'s exit code.
#
#   pup.sh my-branch ./test/run -j '"$CPUQ_CORES"' doc
#   pup.sh my-branch 'python3 test/matrix.py -j "$CPUQ_CORES"'
#   pup.sh --rm my-branch     # remove its pup worktree and pup's copy
#   pup.sh --prune [branch]   # delete test outputs in pup's worktrees
#
# 1. Pushes the branch's commit to pup's bare repo (~/Data/Code/rig.git,
#    pushed by URL; the Mac keeps no `pup` remote), forced: pup mirrors the Mac.
# 2. pup's ~/Data/Code/rig fetches it (remote `mac`) and checks that
#    commit out, detached, in the branch's own worktree
#    /zfs/rig/rig-wt/<branch> (the ZFS pool), which shares that repo's objects and
#    keeps its .zig-cache between runs. Tracked files are reset and
#    untracked ones removed; ignored files (caches, bin/) stay.
# 3. Under pup's cpuq (--cores ${PUP_CORES:-4-16} --priority
#    ${PUP_PRIORITY:-normal} --label rig-pup:<branch>) it runs `zig build -j<grant>`
#    and then <cmd>, with CPUQ_CORES set to the grant.
#
# <cmd> is shell code for bash on pup, as with ssh: the words are joined
# with spaces, so quote what pup's shell should expand ('"$CPUQ_CORES"').
# Only committed work travels; uncommitted edits stay on the Mac.
# Runs on the same branch wait for each other. Ctrl-C stops the job on pup.
#
# Disk: on Linux a full suite + corpus leaves ~40 GB of test executables
# in the worktree's .zig-cache/rig-test (they make reruns fast). pup.sh
# warns below 40 GB free on pup and refuses below 15 GB; --prune
# deletes those outputs (all worktrees, or one branch's).
#
# Exit codes: <cmd>'s own; 125 when the push, checkout or zig build
# fails; 255 when ssh fails.
source "$(dirname "$0")/pup-lib.sh"

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

if [ "${1:-}" = --rm ]; then
    [ $# -eq 2 ] || usage
    pup_bash '
B=$1; WT=$WTS/$B
if git -C "$MAIN" worktree list --porcelain | grep -qxF "worktree $WT"; then
    git -C "$MAIN" worktree remove --force "$WT" && echo "removed $WT"
fi
git -C "$MAIN" update-ref -d "refs/remotes/mac/$B" 2>/dev/null
git -C "$ROOT/rig.git" update-ref -d "refs/heads/$B" 2>/dev/null && echo "deleted $B in rig.git"
rm -f "$WTS/.lock-$2"
d=$(dirname "$WT"); while [ "$d" != "$WTS" ] && rmdir "$d" 2>/dev/null; do d=$(dirname "$d"); done
true' "$2" "$(printf %s "$2" | tr -c 'A-Za-z0-9._-' '_')"
    rc=$?
    git -C "$PUP_REPO" update-ref -d "refs/remotes/pup/$2" 2>/dev/null
    exit $rc
fi

if [ "${1:-}" = --prune ]; then
    [ $# -le 2 ] || usage
    pup_bash '
git -C "$MAIN" worktree list --porcelain | sed -n "s|^worktree \($WTS/.*\)|\1|p" |
while read -r w; do
    [ -z "$1" ] || [ "$w" = "$WTS/$1" ] || continue
    for d in "$w/.zig-cache/rig-test" "$w/.zig-cache/rig-matrix"; do
        [ -d "$d" ] && du -sh "$d" && rm -rf "$d"
    done
done
df -h "$WTS" | tail -1' "${2:-}"
    exit $?
fi

[ $# -ge 2 ] || usage
B=$1; shift
git check-ref-format --branch "$B" >/dev/null 2>&1 || pup_die "not a branch name: $B"
SHA=$(git -C "$PUP_REPO" rev-parse --verify --quiet "refs/heads/$B^{commit}") ||
    pup_die "no local branch $B in $PUP_REPO"
CMD="$*"
STEM=$(printf %s "$B" | tr -c 'A-Za-z0-9._-' '_')

pup_push "$SHA" "refs/heads/$B"

stop_remote() {
    trap - INT TERM HUP
    { kill "$SSH_PID" && wait "$SSH_PID"; } 2>/dev/null
    echo "${0##*/}: stopping the job on pup" >&2
    pup_bash 'f=$WTS/.pid-$1; [ -s "$f" ] && kill -TERM -- "-$(cat "$f")" 2>/dev/null; true' "$STEM"
    exit 130
}
trap stop_remote INT TERM HUP

pup_bash '
B=$1 SHA=$2 STEM=$3 CORES=$4 PRIO=$5 CMD=$6
die() { echo "pup.sh: $*" >&2; exit 125; }
WT=$WTS/$B
mkdir -p "$WTS" || die "cannot create $WTS"
exec 9>"$WTS/.lock-$STEM"
flock -n 9 || { echo "pup.sh: waiting for another run on $B" >&2; flock 9; }
{
    flock 8
    git -C "$MAIN" fetch -q mac "+refs/heads/$B:refs/remotes/mac/$B" ||
        die "fetch of $B into $MAIN failed"
    if ! git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "$MAIN" worktree prune
        git -C "$MAIN" worktree add -q --detach "$WT" "$SHA" ||
            die "worktree add $WT failed"
    fi
} 8>"$WTS/.lock-git"
cd "$WT" || die "no worktree $WT"
git checkout -q --detach --force "$SHA" && git clean -q -fd ||
    die "checkout of $SHA in $WT failed"
free=$(df -Pk "$WT" | awk '"'"'NR==2 { print int($4 / 1048576) }'"'"')
[ "$free" -ge 15 ] || die "only ${free} GB free on pup; free space first (pup.sh --prune)"
[ "$free" -ge 40 ] && echo "pup.sh: $B ${SHA:0:12} in $WT" >&2 ||
    echo "pup.sh: $B ${SHA:0:12} in $WT; warning: ${free} GB free on pup (pup.sh --prune)" >&2
PIDF=$WTS/.pid-$STEM
# Under cpuq on pup, which admits by measured CPU use, keeps the memory
# floor and per-job cap, and holds new work while a timing run is
# exclusive.
setsid cpuq run --cores "$CORES" --priority "$PRIO" --label "rig-pup:$B" -- bash -c "
    zig build -j\"\$CPUQ_CORES\" 2>&1 || { echo \"pup.sh: zig build failed on pup (rc=\$?)\" >&2; exit 125; }
    eval \"\$1\"" pup-job "$CMD" </dev/null &
pid=$!
echo "$pid" >"$PIDF"
wait "$pid"; rc=$?
rm -f "$PIDF"
exit "$rc"' "$B" "$SHA" "$STEM" "${PUP_CORES:-4-16}" "${PUP_PRIORITY:-normal}" "$CMD" &
SSH_PID=$!     # in the background, so a signal reaches the trap at once
wait "$SSH_PID"; rc=$?
[ $rc -eq 255 ] && echo "${0##*/}: ssh to $PUP_HOST failed (or the command exited 255)" >&2
exit $rc
