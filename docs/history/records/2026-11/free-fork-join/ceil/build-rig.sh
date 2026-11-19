#!/bin/bash
# build-rig.sh RIG OUT: fork.rig, fork3.rig and seq.rig built with RIG
# (`rig build --release`), fork.rig a second time as the A/A arm.
set -euo pipefail
cd "$(dirname "$0")"
RIG=${1:?usage: build-rig.sh RIG OUT}; OUT=${2:?}
mkdir -p "$OUT"
"$RIG" build --release -o "$OUT/rig" fork.rig
"$RIG" build --release -o "$OUT/rig3" fork3.rig
"$RIG" build --release -o "$OUT/rig-seq" seq.rig
cp "$OUT/rig" "$OUT/rig-aa"
