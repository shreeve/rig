#!/bin/bash
# usage: p.sh file.rig [new|old] [cmd]
f=$1; which=${2:-new}; cmd=${3:-run}
if [ $which = old ]; then R=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/review-errors/main-wt/bin/rig; else R=/Users/shreeve/Data/Code/rig-errors/bin/rig; fi
$R $cmd $f 2>&1 | head -${LINES:-30}
echo "[exit ${PIPESTATUS[0]}]"
