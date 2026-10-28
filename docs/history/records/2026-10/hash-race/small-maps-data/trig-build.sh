#!/bin/sh
# sm-build.sh RIG NAME [ENV=VAL...]: Trig (full/trig) built release by RIG into sm-trig/packs/NAME.
set -u
W=/zfs/worktrees/rig/sm-trig
T=/zfs/trig-pup/full/trig
rig=$1 name=$2; shift 2
out=$W/packs/$name
rm -rf "$out" && mkdir -p "$out/src"
for d in "$T"/src/*/; do ln -s "$d" "$out/src/$(basename "$d")"; done
cp "$T/tools/trig/main.rig" "$out/src/main.rig"
cd "$out/src"
start=$(date +%s)
env "$@" RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 TRIG_RELEASE_SLOTS='10,11' sh /zfs/trig-pup/trial/slot.sh "$rig" build --release -o "$out/bin" "$out/src/main.rig" > "$out/build.log" 2>&1 || { echo "build $name FAILED"; tail -5 "$out/build.log"; exit 1; }
echo "$name built in $(( $(date +%s) - start )) s"
rm -rf "$out/out"
