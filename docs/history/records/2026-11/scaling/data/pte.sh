#!/bin/bash
# pte.sh: page-table memory (VmPTE) and mappings near the end of a run.
B=/zfs/trig-pup/runs/eq-new/.zig-cache/trig-tests/packs/trig-pgo/bin; R=/zfs/trig-pup/tsrs-shipped/package/tsrs
P=/zfs/trig-pup/full/trig/misc/projects; t="-p tsconfig.trig.json --noEmit"
cores() { case $1 in 1) echo 12;; 4) echo 12-15;; 8) echo 12-19;; esac; }
for proj in ts-pattern zod3; do cd $P/$proj
  for a in trig tsrsg; do for c in 1 4 8; do
    if [ $a = trig ]; then taskset -c $(cores $c) $B $t --checkers $c > /dev/null 2>&1 & else taskset -c $(cores $c) env RAYON_NUM_THREADS=$c $R $t --checkerAssignment go --noLazyMembers --checkers $c > /dev/null 2>&1 & fi
    pid=$!; last=""; while kill -0 $pid 2>/dev/null; do s=$(grep -E "VmPTE|VmRSS" /proc/$pid/status 2>/dev/null | tr -s ' ' | tr '\n' ' '); [ -n "$s" ] && last="$s maps=$(wc -l < /proc/$pid/maps 2>/dev/null)"; sleep 0.01; done
    echo "$proj $a $c: $last"
  done; done
done
