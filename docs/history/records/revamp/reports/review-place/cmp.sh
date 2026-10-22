#!/bin/bash
# cmp.sh DIR : run rig check on both binaries, report diffs
SP=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/review-place
B=$SP/base/bin/rig; N=/Users/shreeve/Data/Code/rig-place/bin/rig
n=0; d=0
for f in "$1"/*.rig; do
  n=$((n+1))
  ob=$(cd $(dirname $f) && $B check $(basename $f) 2>&1; echo "rc=$?")
  on=$(cd $(dirname $f) && $N check $(basename $f) 2>&1; echo "rc=$?")
  if [ "$ob" != "$on" ]; then d=$((d+1)); echo "##### DIFF $(basename $f)"; echo "--- main:"; echo "$ob"; echo "--- branch:"; echo "$on"; fi
  echo "$(basename $f) $(echo "$on" | tail -1)" >> "$1/.status"
done
echo "probes=$n diffs=$d"
