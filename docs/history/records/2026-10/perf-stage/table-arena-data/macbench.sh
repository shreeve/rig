#!/bin/sh
# Mac runtime benches (rig-fast): main caa6f8560 against #832, built once,
# then 3 rounds interleaved, order reversed on even rounds, 3 reps a run.
R=/Users/shreeve/Data/Code/worktrees/rig/item15-alloc
A=/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-practical-hypatia-3af8bd/dbe54b0f-c953-450b-9882-0ae1b99f5bc5/scratchpad/macbench
rig_of() { case $1 in base) echo /Users/shreeve/Data/Code/rig/.git/rig-baseline/caa6f856027f9ee4097f1cb51f115b538ca7b177/rig ;; fix2) echo $R/bin/rig ;; esac; }
mkdir -p $A
for n in base fix2; do
  for b in tasks actors net http; do
    RIG=$(rig_of $n) RIG_OUT_DIR=$A/$n/o-$b python3 $R/bench/$b/bench-$b --variants rig-fast --out $A/$n/$b --build-only > $A/build-$n-$b.log 2>&1 || echo "build $n $b failed"
  done
done
for r in 1 2 3; do
  if [ $((r % 2)) = 0 ]; then order="fix2 base"; else order="base fix2"; fi
  for b in tasks actors net http; do
    for n in $order; do
      echo "== $b $n round $r load $(sysctl -n vm.loadavg)"
      RIG=$(rig_of $n) python3 $R/bench/$b/bench-$b --out $A/$n/$b --time-only --reps 3 --variants rig-fast 2>&1
    done
  done
done
echo "# done $(date +%T)"
