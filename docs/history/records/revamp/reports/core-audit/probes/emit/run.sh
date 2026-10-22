#!/bin/bash
# usage: run.sh file.rig ...   -> check, then sanitize-run if accepted; output kept in file.out
RIG=${RIG:-/Users/shreeve/Data/Code/rig/bin/rig}
for f in "$@"; do
  o="${f%.rig}.out"
  echo "=== $f"
  out=$($RIG check "$f" 2>&1); st=$?
  if [ $st -ne 0 ]; then { echo "REJECTED:"; echo "$out" | head -8; } | tee "$o"; continue; fi
  RIG_SANITIZE=1 timeout 120 $RIG run "$f" > "$o.tmp" 2>&1; rs=$?
  { echo "ACCEPTED exit=$rs"; head -40 "$o.tmp"; } | tee "$o"; rm -f "$o.tmp"
done
