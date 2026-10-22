#!/bin/bash
# usage: r.sh cmd file
export RIG_OUT_DIR=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R13/out
cmd=$1; shift
for f in "$@"; do echo "=== $f"; gtimeout 60 /Users/shreeve/Data/Code/rig/bin/rig $cmd "$f" 2>&1 | head -40; echo "[exit ${PIPESTATUS[0]}]"; done
