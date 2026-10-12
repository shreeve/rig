#!/bin/bash
# The string-scan sweep and the competitors, on one machine.
#   xbench.sh build OUT   build every variant and competitor (under cpuq, any load)
#   xbench.sh time OUT    time them, interleaved, fastest of $REPS (default 15)
#                         (run it on a quiet machine: cpuq run --exclusive)
#   xbench.sh perf OUT    cycles and instructions per byte (Linux perf stat)
# Rig variants: rig-safe@TIER=T is the landed 16-lane scan with a SWAR stage
# of T bytes (1000000000: SWAR only); rig-safe@src=json32+TIER=T is the same
# with 32-lane blocks (variants/simd32.py). Set PIN=CPU to pin the timing
# to one core with taskset (Linux).
set -e
H=$(cd "$(dirname "$0")" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
SWEEP=
for T in 1000000000 16 32 64; do SWEEP+="rig-safe@TIER=$T,rig-safe@src=json32+TIER=$T,"; done
RIG_VARS=${SWEEP%,}
INL=rig-safeinl@TIER=16,rig-safeinl@src=json32+TIER=16,rig-safeinl@src=json32+TIER=64   # maskFirst inlined (bench-json --help)
COMP=zig-tape-safe,zig-tape-fast,zimdjson-dom-fast,serde_json,simd-json-tape,sonic-rs
case $1 in
  build)
    "$H/../../tools/fetch-json-data.sh"
    python3 "$H/variants/simd32.py" "$OUT/v"
    JSON_DIR=$OUT/v "$H/bench-json" --out "$OUT" --build-only --variants "$RIG_VARS,$INL,zig-tape-safe,zig-tape-fast"
    "$H/rust-bench/build.sh" native
    "$H/zimdjson/build.sh" dom fast ;;
  time)
    BENCH_OUT=$OUT python3 "$H/timers/time.py" "$RIG_VARS,$INL,$COMP" "${REPS:-15}" ;;
  perf)
    python3 "$H/timers/perf.py" "$OUT" twitter,twitterescaped,canada,citm_catalog,gsoc-2018,github_events \
      "${PERF_VARS:-rig-safe@TIER=16,sonic-rs}" "${PIN:-6}" ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
