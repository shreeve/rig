#!/bin/bash
# arm.sh NAME: build the package $P/arm-NAME into $P/bin/NAME/trig, as rig build --release does
set -e
P=$(cd "$(dirname "$0")" && pwd); d=$P/arm-$1; mkdir -p $P/bin/$1
tools/heavy zig build-exe -Osafe -fomit-frame-pointer --cache-dir $d/.zig-cache $d/__rig_main.zig -femit-bin=$P/bin/$1/trig
rm -rf $d/.zig-cache
