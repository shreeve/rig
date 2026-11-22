#!/bin/bash
# mk.sh ROOT.zig OUT: build a Rig package's root as rig build --release does.
set -e
P=~/Data/Code/Claude/rig/rig/bt200-panel/probes-compiler
F="-Osafe -fomit-frame-pointer -fno-stack-protector -mcpu=native+reserve_x15"
zig build-obj $F --cache-dir $P/pkg/.zig-cache $1 -femit-bin=$P/$2.o -lc
python3 -I $P/apart.py $P/$2.o $P/$2-apart.o
zig build-exe $F --cache-dir $P/pkg/.zig-cache $P/$2-apart.o -lc -femit-bin=$P/$2
rm -f $P/$2.o $P/$2-apart.o
