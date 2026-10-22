#!/bin/bash
# usage: t.sh file.rig [run|check|emit] [extra]
export RIG_OUT_DIR=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R15/out
f=$1; shift; cmd=${1:-run}; shift
gtimeout 60 /Users/shreeve/Data/Code/rig/bin/rig $cmd "$@" $f 2>&1 | head -40
echo "[exit ${PIPESTATUS[0]}]"
