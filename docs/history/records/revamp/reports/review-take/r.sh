#!/bin/sh
# run each file given, print output
for f in "$@"; do echo "=== $f"; /Users/shreeve/Data/Code/rig/bin/rig run "$f" 2>&1 | head -40; done
