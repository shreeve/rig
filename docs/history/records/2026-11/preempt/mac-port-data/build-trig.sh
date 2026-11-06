#!/bin/sh
# build-trig.sh ARM RIG: a release trig as tests/lib.rip's release pack builds it
set -eu
S=$(cd "$(dirname "$0")" && pwd -P)
arm=$1; rig=$2
d=$S/packs/$arm
rm -rf "$d"; mkdir -p "$d/src"
cp $S/trig/tools/trig/main.rig "$d/src/main.rig"
for m in $S/trig/src/*/; do ln -s "$(cd "$m" && pwd -P)" "$d/src/$(basename "$m")"; done
cd "$d/src"
RIG="$rig" RIG_OUT_DIR="$d/out" RIG_NO_CRASH_REPORT=1 \
  $S/trig/tools/trig/gen-libtrees "$d/src" "$rig" build --release -o "$d/bin" "$d/src/main.rig" > "$d/build.log" 2>&1
echo "$d/bin"
