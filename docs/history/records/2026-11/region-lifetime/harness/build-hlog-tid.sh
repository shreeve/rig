#!/bin/bash
# build-hlog.sh DIR: a heap-log build (RIG_HEAP_PROFILE=sites, frame pointers, debug info; heapmiss's scratch Rig,
# the pin + the event log) of DIR/tree into DIR/heap. Run inside cpuq.
set -eu
. ~/cpuq/tmp/setup1123/env.sh
RIG=/home/shreeve/cpuq/tmp/regionmodel/rigtid/bin/rig
export TRIG_RIG_OVERRIDE=1
D=$(cd "$1" && pwd)
B=$D/hbld
rm -rf -- "$B"; mkdir -p "$B/src"
for m in "$D"/tree/src/*/; do n=$(basename "$m"); [ "$n" = checks ] && continue; ln -s "${m%/}" "$B/src/$n"; done
mkdir "$B/src/checks"
for f in "$D"/tree/src/checks/*; do [ "$(basename "$f")" = checks.rig ] || cp "$f" "$B/src/checks/"; done
sed 's/^pub CHECK_IDS = true$/pub CHECK_IDS = false/' "$D/tree/src/checks/checks.rig" > "$B/src/checks/checks.rig"
grep -q '^pub CHECK_IDS = false$' "$B/src/checks/checks.rig"
sed 's/^  os.exit(status.code()) if not target.debug$/  _ = status/' "$D/tree/tools/trig/main.rig" > "$B/src/main.rig"
grep -q '^  _ = status$' "$B/src/main.rig"
export RIG_OUT_DIR=$B/out TRIG_TARGET_CPU=meteorlake TRIG_REAL_ZIG=$(command -v zig) ZIG=$HOME/cpuq/tmp/rss/zig-fp RIG_HEAP_PROFILE=sites
"$D/tree/tools/trig/gen-libtrees" "$B/src" "$RIG" build --release --units=32 -o "$D/heap" "$B/src/main.rig" > "$D/heapbuild.log" 2>&1 || { tail -20 "$D/heapbuild.log" >&2; exit 1; }
rm -rf -- "$B"
echo "built $D/heap"
