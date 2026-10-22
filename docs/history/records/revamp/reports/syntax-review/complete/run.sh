#!/bin/bash
# usage: ./run.sh name  (reads name.rig)
for f in "$@"; do echo "=== $f"; /Users/shreeve/Data/Code/rig/bin/rig run $f.rig 2>&1 | head -30; done
