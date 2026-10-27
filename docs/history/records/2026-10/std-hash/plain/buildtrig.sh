#!/bin/sh
# buildtrig.sh RIG TRIGDIR NAME [release|pgo]: TRIGDIR's Trig built by RIG,
# `rig build --release`, or with `--pgo` trained by TRIGDIR's bolt-train,
# into packs/NAME/bin, through a release slot. RIG_STD reaches the build.
set -eu
W=/zfs/worktrees/rig/std-hash
rig=$1 T=$2 name=$3 mode=${4:-release}
out=$W/packs/$name
rm -rf "$out" && mkdir -p "$out/src"
for d in "$T"/src/*/; do ln -s "$d" "$out/src/$(basename "$d")"; done
cp "$T/tools/trig/main.rig" "$out/src/main.rig"
cd "$out/src"
start=$(date +%s)
if [ "$mode" = pgo ]; then
  RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release --pgo -o "$out/bin" "$out/src/main.rig" -- "$T/tools/trig/bolt-train" "$out/bin" > "$out/build.log" 2>&1
else
  RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release -o "$out/bin" "$out/src/main.rig" > "$out/build.log" 2>&1
fi
echo "$name built in $(( $(date +%s) - start )) s" >> "$out/build.log"
rm -rf "$out/out"
