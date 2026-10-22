#!/bin/bash
# usage: t.sh NAME [check|run|emit] < spec   (spec: "--- file.rig" separators)
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R11b
name=$1; cmd=${2:-run}
d=$S/cases/$name; rm -rf $d; mkdir -p $d
awk -v d="$d" '/^--- /{f=d"/"$2; next} {print > f}' 
cd $d
export RIG_OUT_DIR=$S/out/$name
gtimeout 60 /Users/shreeve/Data/Code/rig/bin/rig $cmd main.rig 2>&1
echo "[exit $?]"
