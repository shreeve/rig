#!/bin/sh
# buildtrig.sh RIG NAME: Trig (~/Data/Code/trig, read-only) built by RIG with --release into $SP/packs/NAME/bin
set -eu
SP=${SP:-$PWD}
T=$HOME/Data/Code/trig
rig=$1 name=$2 out=$SP/packs/$2
rm -rf "$out" && mkdir -p "$out/src"
for s in $T/src/*/; do ln -s "$s" "$out/src/$(basename "$s")"; done
cp $T/tools/trig/main.rig "$out/src/main.rig"
cd "$out/src"
RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 "$rig" build --release -o "$out/bin" "$out/src/main.rig" > "$out/build.log" 2>&1 || { tail -20 "$out/build.log"; exit 1; }
rm -rf "$out/out"
echo "built $name: $(shasum -a 256 $out/bin | cut -c1-16)"
