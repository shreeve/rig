#!/bin/bash
# Compare baseline and new `rig check` output for each file given.
D=$(dirname "$0")
for f in "$@"; do
  a=$($D/base/bin/rig check "$f" 2>&1); b=$(/Users/shreeve/Data/Code/rig-place/bin/rig check "$f" 2>&1)
  if [ "$a" == "$b" ]; then echo "== $f: same"; echo "$a" | grep -E "error|note" | head -3; else echo "== $f: DIFF"; echo "-- old:"; echo "$a" | grep -E "error|note"; echo "-- new:"; echo "$b" | grep -E "error|note"; fi
done
