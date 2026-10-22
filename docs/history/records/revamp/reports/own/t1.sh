#!/bin/bash
# usage: t1.sh file.rig  -> prints "== file: CHECK-REJECT ..." or run output
RIG=${RIG:-/Users/shreeve/Data/Code/rig-rv-own/bin/rig}
f=$1
out=$($RIG check "$f" 2>&1); rc=$?
if [ $rc -ne 0 ]; then
  echo "== $f: REJECTED"; echo "$out" | head -6 | sed 's/^/   /'
else
  r=$(timeout 120 $RIG run "$f" 2>&1); rrc=$?
  echo "== $f: ACCEPTED run-exit=$rrc"; echo "$r" | head -${LINES_MAX:-25} | sed 's/^/   /'
fi
