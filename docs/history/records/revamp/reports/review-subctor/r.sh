#!/bin/bash
# usage: r.sh file.rig  -> runs and prints output
for f in "$@"; do echo "=== $f"; /Users/shreeve/Data/Code/rig/bin/rig run "$f" 2>&1 | head -30; echo "[exit ${PIPESTATUS[0]}]"; done
