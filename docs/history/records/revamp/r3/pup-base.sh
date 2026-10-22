#!/bin/bash
# pup-base.sh <commit>: build the compiler at <commit> on pup, as the base
# for test/equiv.py there, and print the base's path on pup
# (~/Data/Code/rig-bases/<sha12>/rig).
#
# The commit goes to pup's bare repo under refs/pup-base/ (so it need not
# be on GitHub or on a branch), is built (`zig build`, debug, like the
# Mac's r3/rig-*-base copies) in a throwaway worktree under cpuq
# (--cores 2-8 --priority ${PUP_PRIORITY:-normal}), and its bin/ is kept.
# A base that already exists is reused. Then, for example:
#
#   base=$(pup-base.sh main)
#   pup.sh my-branch "python3 test/equiv.py $base bin/rig -j \"\$CPUQ_CORES\""
#
# Remove old bases with: ssh pup rm -rf Data/Code/rig-bases/<sha12>
D=$(cd "$(dirname "$0")" && pwd)
source "$D/pup-lib.sh"

[ $# -eq 1 ] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
SHA=$(git -C "$PUP_REPO" rev-parse --verify --quiet "$1^{commit}") || pup_die "no commit $1"
pup_push "$SHA" "refs/pup-base/$SHA"

pup_bash '
SHA=$1 PRIO=$2 S=${1:0:12}
OUT=$ROOT/rig-bases/$S WT=$WTS/.base-$S
die() { echo "pup-base.sh: $*" >&2; exit 125; }
drop() { cd / && git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null
         git -C "$MAIN" update-ref -d "refs/pup-base/$SHA"
         git -C "$ROOT/rig.git" update-ref -d "refs/pup-base/$SHA"; }
mkdir -p "$WTS" "$ROOT/rig-bases" || die "cannot create $WTS"
exec 9>"$WTS/.lock-base-$S"; flock 9          # one build of a base at a time
if [ -x "$OUT/rig" ]; then drop; echo "$OUT/rig"; exit 0; fi
{
    flock 8
    git -C "$MAIN" fetch -q mac "+refs/pup-base/$SHA:refs/pup-base/$SHA" || die "fetch of $S failed"
    git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null; git -C "$MAIN" worktree prune
    git -C "$MAIN" worktree add -q --detach "$WT" "$SHA" || die "worktree add $WT failed"
} 8>"$WTS/.lock-git"
cd "$WT" || die "no worktree $WT"
echo "pup-base.sh: building $S in $WT" >&2
if ! cpuq run --cores 2-8 --priority "$PRIO" --label "rig-pup-base:$S" -- zig build </dev/null >&2; then
    drop; die "zig build at $S failed"
fi
rm -rf "$OUT.tmp" && mkdir -p "$OUT.tmp" && cp -p bin/* "$OUT.tmp/" && mv "$OUT.tmp" "$OUT" ||
    { drop; die "cannot copy bin/ to $OUT"; }
drop
echo "$OUT/rig"' "$SHA" "${PUP_PRIORITY:-normal}"
rc=$?
[ $rc -eq 255 ] && echo "${0##*/}: ssh to $PUP_HOST failed" >&2
exit $rc
