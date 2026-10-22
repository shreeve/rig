#!/bin/bash
# usage: r.sh file.rig  -> check then run
R=/Users/shreeve/Data/Code/rig-lang4/bin/rig
for f in "$@"; do echo "=== $f"; $R run "$f" 2>&1 | tail -25; echo "[exit $?]"; done
