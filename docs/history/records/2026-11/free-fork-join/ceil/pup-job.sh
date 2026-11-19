#!/bin/bash
# pup-job.sh build OUT [RIG]   copy these sources to OUT/src and build the
#                              ceiling's arms, the Rayon twins and, given
#                              RIG (a bin/rig), fork.rig, fork3.rig and
#                              seq.rig, all on E-cores 12-19, no slot needed
# pup-job.sh time OUT          the two boards, 20 rounds each, at 1 worker
#                              (core 6) and 12 (cores 0-11), the driver on
#                              core 8: run it inside an ab slot the Rig
#                              session opens (about 15 minutes)
# pup-job.sh all OUT [RIG]     build, then time
#
# OUT is a fresh folder on /zfs (binaries and outputs never on /tmp).
# The boards write OUT/board1.json (one psum and one qsort a process, as
# the record's board) and OUT/board3.json (three of each a process: the
# cold pass, then two warm), their logs, and OUT/board1.txt and
# OUT/board3.txt (stats.py: medians, ranges, ratios to the ceiling paired
# by round). Every sum is checked as it is read; a wrong one stops the
# board. The Rig arms run only when RIG was given to `build`.
set -euo pipefail
CMD=${1:?usage: pup-job.sh build|time|all OUT [RIG]}
OUT=${2:?usage: pup-job.sh build|time|all OUT [RIG]}
RIG=${3:-}
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=$HOME/.cargo/bin:$HOME/.local/bin:$PATH PYTHONUNBUFFERED=1
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

build() {
    rm -rf "$OUT/src"
    mkdir -p "$OUT/src" "$OUT/bin"
    (cd "$HERE" && tar --exclude=target --exclude=bin --exclude='arm_*.zig' -cf - \
        ceil.zig rigsort.zig sortstub.zig build.sh build-rig.sh build-rayon.sh board.py stats.py \
        fork.rig fork3.rig seq.rig rayon rayon3) | (cd "$OUT/src" && tar -xf -)
    { uname -a; zig version; cargo --version; } >"$OUT/build.txt" 2>&1
    taskset -c 12-19 "$OUT/src/build.sh" "$OUT/bin" >"$OUT/build-ceil.log" 2>&1 || { tail -20 "$OUT/build-ceil.log"; exit 1; }
    taskset -c 12-19 "$OUT/src/build-rayon.sh" "$OUT/bin" >"$OUT/build-rayon.log" 2>&1 || { tail -20 "$OUT/build-rayon.log"; exit 1; }
    if [[ -n $RIG ]]; then
        echo "rig: $RIG $("$RIG" --version 2>&1 | head -1)" >>"$OUT/build.txt"
        RIG_OUT_DIR=$OUT/pkg taskset -c 12-19 "$OUT/src/build-rig.sh" "$RIG" "$OUT/bin" >"$OUT/build-rig.log" 2>&1 || { tail -20 "$OUT/build-rig.log"; exit 1; }
    fi
    ls -la "$OUT/bin"
}

# The monitor arms (mon, mon3) are left out on Linux: there they stop at
# their start with an errno Zig's wrapper treats as unreachable (std/c.zig,
# `errno`), not yet traced. all4 holds the monitor too and is kept; the
# Mac's boards measured the monitor alone.
timing() {
    local B=$OUT/bin rig1=() rig3=()
    [[ -x $B/rig ]] && rig1=(rig="$B/rig" rig-aa="$B/rig-aa" rig-seq="$B/rig-seq")
    [[ -x $B/rig3 ]] && rig3=(rig="$B/rig3")
    export WORKERS="1 12" PIN="1:6,12:0-11"
    cd "$OUT"
    taskset -c 8 python3 src/board.py 20 board1.json ceil="$B/ceil" aa="$B/ceil-aa" heap="$B/heap" stack="$B/stack" \
        sc="$B/sc" all4="$B/all4" seq="$B/seq" "${rig1[@]}" rayon="$B/rayon" >board1.log 2>&1
    taskset -c 8 python3 src/board.py 20 board3.json ceil="$B/ceil3" aa="$B/ceil3-aa" heap="$B/heap3" stack="$B/stack3" \
        sc="$B/sc3" all4="$B/all43" "${rig3[@]}" rayon="$B/rayon3" >board3.log 2>&1
    python3 src/stats.py ceil board1.json >board1.txt
    python3 src/stats.py ceil board3.json >board3.txt
    echo "done: $OUT/board1.txt $OUT/board3.txt"
}

case $CMD in
build) build ;;
time) timing ;;
all) build; timing ;;
*) echo "pup-job.sh: build, time or all, not '$CMD'" >&2; exit 2 ;;
esac
