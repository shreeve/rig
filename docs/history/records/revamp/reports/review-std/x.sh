#!/bin/bash
for f in "$@"; do echo "=== $f"; /Users/shreeve/Data/Code/rig-std/bin/rig run $f > out.txt 2>&1; c=$?; grep -v "^\s*[/^?]" out.txt | grep -v "^    " | head -${N:-10}; echo "[exit $c]"; done
