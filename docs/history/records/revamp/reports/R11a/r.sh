#!/bin/bash
# usage: r.sh <dir> [cmd]
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R11a
d=$1; cmd=${2:-run}
mkdir -p $S/out/$(basename $d)
RIG_OUT_DIR=$S/out/$(basename $d) /Users/shreeve/Data/Code/rig/bin/rig $cmd $d/main.rig 2>&1
echo "[exit $?]"
