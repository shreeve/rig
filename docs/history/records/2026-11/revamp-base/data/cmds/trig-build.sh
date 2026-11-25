#!/bin/bash
# trig-build.sh RIG TRIGDIR N OUTROOT: N release builds of Trig (`RIG build --release -o trig main.rig` in TRIGDIR),
# each into a fresh RIG_OUT_DIR under OUTROOT (no Zig cache of its own), with zig run through cmds/zigtime so each
# zig invocation's wall time is logged. Prints total wall, the Zig steps' wall (first start to last end), and size.
set -u
RIG=$1; TD=$2; n=${3:-2}; OR=$4; H=$(cd "$(dirname "$0")" && pwd)
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
echo "# $(uname -sm) $(hostname -s) rig $($RIG --version 2>&1 | head -1) zig $(zig version) load: $(uptime | sed 's/.*load averages*: //')"
for i in $(seq 1 $n); do
  O=$OR/trig-out-$i; rm -rf "$O" "$OR/trig-$i" "$OR/zig-$i.log"; mkdir -p "$O"
  s=$(now); (cd "$TD" && RIG_OUT_DIR=$O ZIG=$H/zigtime ZIGTIME_LOG=$OR/zig-$i.log RIG_NO_CRASH_REPORT=1 $RIG build --release -o "$OR/trig-$i" main.rig > "$OR/build-$i.log" 2>&1); rc=$?; e=$(now)
  z=$(awk 'NR==1{a=$1} {b=$2} END{printf "%.1f", b-a}' "$OR/zig-$i.log")
  sz=$(stat -c %s "$OR/trig-$i" 2>/dev/null || stat -f %z "$OR/trig-$i")
  printf 'build %d rc=%d total_s=%.1f zig_s=%s zig_calls=%d trig_bytes=%s\n' $i $rc $(echo "$e - $s" | bc) $z $(wc -l < "$OR/zig-$i.log") $sz
done
