#!/bin/zsh
# usage: run.sh file.rig...  runs each with the text-branch compiler
for f in "$@"; do
  echo "=== $f"
  /Users/shreeve/Data/Code/rig-text/bin/rig run "$f" 2>&1 | head -${LINES_MAX:-20}
done
