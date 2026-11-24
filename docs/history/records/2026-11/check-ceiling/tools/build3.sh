#!/bin/sh
# build3.sh NAME RIG TRIGSHA: build.sh with Trig at commit TRIGSHA (git archive of src and tools into
# ceiling/trig-SHA), no instrumentation. Output ceiling/NAME/bin (and its dSYM).
set -u
n=$1; RIG=$2; S=$3; H=$HOME/Data/Code/Claude/rig/rig/ceiling; T=$H/trig-$S; D=$H/$n
[ -x "$D/bin" ] && { echo "$n cached"; exit 0; }
if [ ! -d "$T" ]; then mkdir -p "$T.tmp" && git -C $HOME/Data/Code/trig archive "$S" src tools | tar -x -C "$T.tmp" && mv "$T.tmp" "$T"; fi
rm -rf "$D"; mkdir -p "$D/src"
cp "$T/tools/trig/main.rig" "$D/src/main.rig"
for m in "$T"/src/*; do ln -s "$m" "$D/src/"; done
t0=$(date +%s)
( cd "$D" && TRIG_RIG_OVERRIDE=1 RIG="$RIG" RIG_OUT_DIR="$D/out" RIG_NO_CRASH_REPORT=1 \
  $HOME/Data/Code/rig/tools/heavy "$T/tools/trig/gen-libtrees" "$D/src" "$RIG" build --release -o "$D/bin" "$D/src/main.rig" ) > "$D.log" 2>&1
echo "$n rc=$? $(( $(date +%s) - t0 ))s $(stat -f %z "$D/bin" 2>/dev/null)"
