#!/bin/bash
# usage: t.sh file.rig ... : check then run each
RIG=/Users/shreeve/Data/Code/rig/bin/rig
for f in "$@"; do
  echo "=== $f"
  out=$($RIG check "$f" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then echo "[rejected] $out" | head -5; continue; fi
  timeout 120 $RIG run "$f" 2>&1 | head -${LINES_MAX:-25}
  echo "[exit ${PIPESTATUS[0]}]"
done
