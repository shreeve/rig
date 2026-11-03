#!/bin/sh
# usage: build.sh SRCROOT OUTBIN
set -e
RIG=${RIG:-/Users/shreeve/Data/Code/rig/.git/rig-baseline/2e30e84572b147f9fd2b5cf3d383b6178433e3f6/rig}
S=/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-rig-production-agent-6dff9f/3f64bb60-d18e-40a4-bf7b-73ae5aadde91/scratchpad/parser
L=$(mktemp -d $S/links.XXXX); O=$(mktemp -d $S/out.XXXX)
for d in "$1"/src/*; do ln -s "$d" "$L/$(basename $d)"; done
ln -s "$1/tools/trig/main.rig" "$L/main.rig"
cd "$L" && RIG_OUT_DIR=$O $RIG build --release -o "$2" main.rig
rm -rf "$L" "$O"
