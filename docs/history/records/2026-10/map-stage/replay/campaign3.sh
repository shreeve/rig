#!/bin/sh
# The dense2 bound: one binary for every design, core 8 (sibling 9 idle).
set -u
cd /zfs/worktrees/rig/map-dense2   # harness/ holds replay.zig, alloc.zig, bench.sh; replay-safe3 is its ReleaseSafe build
H=harness B=harness/replay-safe3 T=/zfs/worktrees/rig/map-replay/.replay/traces
sh $H/bench.sh $T/c1.bin $B 11 8 9 all-safe3 today cand_nf2 dense2 dense2e noop > results/all-safe3.txt
sh $H/bench.sh $T/c1.bin $B 7 8 9 pollute64M-3 today cand_nf2 dense2 dense2e noop -- --pollute 65536 > results/pollute3.txt
for s in 0 1 2 3; do
  sh $H/bench.sh $T/c1.bin $B 11 8 9 shape$s-3 today cand_nf2 dense2 dense2e noop -- --only $s > results/shape$s-3.txt
done
for d in today dense2 cand_nf2; do taskset -c 8 $B $T/c1.bin $d --mem 2>&1 | grep -E "MEM|RESULT" | sed "s/^/$d /"; done > results/mem3.txt
echo done > results/DONE3
