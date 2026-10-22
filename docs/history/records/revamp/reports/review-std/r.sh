#!/bin/bash
# run each probe
for f in "$@"; do echo "=== $f"; /Users/shreeve/Data/Code/rig-std/bin/rig run "$f" 2>&1 | head -${N:-15}; echo "[exit ${PIPESTATUS[0]}]"; done
