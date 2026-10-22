#!/bin/bash
export RIG_OUT_DIR=$(dirname $0)/../out
R=/Users/shreeve/Data/Code/rig/bin/rig
f=$1; mode=${2:-run}; n=${3:-4}
echo "--- $f"; $R $mode $f.rig 2>&1 | grep -v "^note: the package" | head -$n
