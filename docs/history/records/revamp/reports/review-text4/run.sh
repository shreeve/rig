#!/bin/bash
for f in "$@"; do echo "=== $f"; /Users/shreeve/Data/Code/rig-text/bin/rig run "$f" 2>&1 | head -${N:-30}; done
