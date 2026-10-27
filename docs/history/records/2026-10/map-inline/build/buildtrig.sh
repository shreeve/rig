#!/bin/sh
# buildtrig.sh RIG NAME [release|pgo]: Trig main (trig/) built by RIG,
# `rig build --release` or with `--pgo` trained by Trig's workload
# (tools/trig/bolt-train, as tools/trig/pgo trains it), into
# packs/NAME/bin, through a release slot.
set -eu
W=/zfs/worktrees/rig/map-inline
rig=$1 name=$2 mode=${3:-release}
out=$W/packs/$name
rm -rf "$out" && mkdir -p "$out/src"
for d in "$W"/trig/src/*/; do ln -s "$d" "$out/src/$(basename "$d")"; done
cp "$W/trig/tools/trig/main.rig" "$out/src/main.rig"
cd "$out/src"
start=$(date +%s)
if [ "$mode" = pgo ]; then
  RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release --pgo -o "$out/bin" "$out/src/main.rig" -- "$W/trig/tools/trig/bolt-train" "$out/bin" > "$out/build.log" 2>&1
else
  RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release -o "$out/bin" "$out/src/main.rig" > "$out/build.log" 2>&1
fi
echo "$name built in $(( $(date +%s) - start )) s" >> "$out/build.log"
[ "${KEEP_OUT:-}" ] || rm -rf "$out/out"
