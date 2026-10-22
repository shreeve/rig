#!/bin/bash
# usage: both.sh file.rig [cmd]
f=$1; c=${2:-run}
echo "== NEW"; /Users/shreeve/Data/Code/rig-sc5/bin/rig $c $f 2>&1 | head -${N:-20}
echo "== MAIN"; /Users/shreeve/Data/Code/rig/bin/rig $c $f 2>&1 | head -${N:-20}
