#!/bin/sh
# build.sh NAME RIG: release build of Trig at ~/Data/Code/trig HEAD (faeb512b) with RIG, as
# c8-check/build.sh does, without its checkerpool swap. Output ceiling/NAME/bin.
set -u
n=$1; RIG=$2; H=$HOME/Data/Code/Claude/rig/rig/ceiling; T=$HOME/Data/Code/trig; D=$H/$n
[ -x "$D/bin" ] && { echo "$n cached"; exit 0; }
rm -rf "$D"; mkdir -p "$D/src"
cp "$T/tools/trig/main.rig" "$D/src/main.rig"
for m in "$T"/src/*; do ln -s "$m" "$D/src/"; done
t0=$(date +%s)
( cd "$D" && TRIG_RIG_OVERRIDE=1 RIG="$RIG" RIG_OUT_DIR="$D/out" RIG_NO_CRASH_REPORT=1 \
  $HOME/Data/Code/rig/tools/heavy "$T/tools/trig/gen-libtrees" "$D/src" "$RIG" build --release -o "$D/bin" "$D/src/main.rig" ) > "$D.log" 2>&1
echo "$n rc=$? $(( $(date +%s) - t0 ))s $(stat -f %z "$D/bin" 2>/dev/null)"
