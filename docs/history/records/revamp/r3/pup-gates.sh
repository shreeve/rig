#!/bin/bash
# pup-gates.sh <branch> <log-prefix>: the merge gates for a local branch,
# run on pup (Linux x86_64) through pup.sh: the suite, the corpus, the
# matrix, `zig build test` with a fresh cache, and
# `./test/run oracle doc vocab`, one after another, each with as many
# workers as the cpuq grant (CPUQ_CORES). The logs come back to the Mac
# as <log-prefix>.suite .corpus .matrix .unit .odv, with a summary in
# <log-prefix>.sum like gates.sh's (plus each gate's time); the summary
# also streams as the gates run. Exits non-zero if any gate fails (125 if
# the branch could not be built or the logs not fetched).
#
# Afterwards the worktree's test outputs are deleted (about 40 GB on
# Linux) unless PUP_KEEP_CACHE=1. The shared build store
# (RIG_BUILD_STORE) is kept between runs so later branches start warm,
# but removed before a run when under 60 GB is free on its filesystem,
# the room a cold run needs (about 50 GB). On pup the store is a link
# to /zfs/rig/rig-build-store, on the internal NVMe's ZFS pool. PUP_CORES and PUP_PRIORITY pass to
# pup.sh. GATES_DELTA=1 runs the suite, corpus and matrix with --delta
# (pup's own results cache, beside its store; gates.sh).
#
#   pup-gates.sh my-branch .git/revamp/r3/logs/my-branch-pup
D=$(cd "$(dirname "$0")" && pwd)
source "$D/pup-lib.sh"

[ $# -eq 2 ] || { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
B=$1; P=$2
mkdir -p "$(dirname "$P")" || pup_die "cannot create the directory of $P"
STEM=$(printf %s "$B" | tr -c 'A-Za-z0-9._-' '_')
RLOG=/zfs/rig/rig-wt/.logs/$STEM-$(date +%Y%m%d-%H%M%S)-$$   # on pup's ZFS pool

GATES='L='"$RLOG"' KEEP='"${PUP_KEEP_CACHE:-0}"' DELTA='"${GATES_DELTA:-0}"'
J=${CPUQ_CORES:-2}; mkdir -p "$L"; fail=0
DF=; [ "$DELTA" = 1 ] && DF=--delta
echo "pup $(git rev-parse --short HEAD) -j $J $DF" | tee "$L/sum"
S=$(cd "$(git rev-parse --git-common-dir)" && pwd)/rig-build-store
free=$(df -Pk "$S/" 2>/dev/null | awk '"'"'NR==2 { print int($4 / 1048576) }'"'"')
if [ -d "$S" ] && [ "${free:-0}" -lt 60 ]; then
    rm -rf "$S"; echo "build store removed first (${free} GB free)" | tee -a "$L/sum"
fi
gate() {
    local n=$1; shift; local t0=$SECONDS
    "$@" >"$L/$n" 2>&1; local rc=$?
    echo "$n rc=$rc (-j $J, $((SECONDS - t0))s)" | tee -a "$L/sum"
    [ $rc -eq 0 ] || fail=1
}
[ -x tools/fetch-json-data.sh ] && { tools/fetch-json-data.sh >"$L/fetch" 2>&1 || fail=1; tail -1 "$L/fetch" | tee -a "$L/sum"; export JSON_REQUIRE_DATA=1; }
# The full gates run every grid in full (each test says what its _FULL adds).
export LANE_GRID_FULL=1 INLINE_GRID_FULL=1 INLINE_BUDGET_FULL=1
gate suite ./test/run -j $J $DF;               tail -1 "$L/suite" | tee -a "$L/sum"
gate corpus ./test/run -j $J $DF corpus;       tail -1 "$L/corpus" | tee -a "$L/sum"
gate matrix python3 test/matrix.py -j $J $DF --keep "$PWD/.zig-cache/rig-matrix"
tail -2 "$L/matrix" | tee -a "$L/sum"
U=$(mktemp -d)
gate unit zig build test -j"$J" --summary all --cache-dir "$U"; rm -rf "$U"
grep -E "tests? passed|Build Summary" "$L/unit" | tail -2 | tee -a "$L/sum"
gate odv ./test/run -j $J oracle doc vocab; tail -1 "$L/odv" | tee -a "$L/sum"
[ "$KEEP" = 1 ] || rm -rf .zig-cache/rig-test .zig-cache/rig-matrix
exit $fail'

"$D/pup.sh" "$B" "$GATES" &
PID=$!
trap 'kill -TERM "$PID" 2>/dev/null' INT TERM HUP   # pup.sh stops the job on pup
while :; do
    wait "$PID"; rc=$?
    kill -0 "$PID" 2>/dev/null || break
done
trap - INT TERM HUP

# Fetch the logs whatever happened, then drop pup's copy.
tmp=$(mktemp -d)
if pup_bash 'cd "$1" && tar -cf - .' "$RLOG" | tar -xf - -C "$tmp" 2>/dev/null &&
    [ -s "$tmp/sum" ]; then
    for f in "$tmp"/*; do mv "$f" "$P.$(basename "$f")"; done
    pup_bash 'rm -rf "$1"' "$RLOG"
    echo "logs: $P.{sum,suite,corpus,matrix,unit,odv}"
else
    echo "${0##*/}: no logs fetched from pup:$RLOG" >&2
    [ $rc -eq 0 ] && rc=125
fi
rm -rf "$tmp"
exit $rc
