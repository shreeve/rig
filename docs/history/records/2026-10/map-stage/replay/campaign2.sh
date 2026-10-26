#!/bin/sh
# The second measurement, with the tuned candidate, one binary for every design.
set -u
cd /zfs/worktrees/rig/map-replay/.replay
H=harness B=harness/replay-safe2
sh $H/bench.sh traces/c1.bin $B 11 8 9 all-safe2 today today_nf cand cand2 cand_nf cand_nf2 cand_nf_sh cand_nf_ph noop > results/all-safe2.txt
sh $H/bench.sh traces/c1.bin $B 11 8 9 pollute64M-2 today cand cand2 cand_nf cand_nf2 cand_nf_sh cand_nf_ph noop -- --pollute 65536 > results/pollute2.txt
for s in 0 1 2 3; do
  sh $H/bench.sh traces/c1.bin $B 11 8 9 shape$s-2 today cand2 cand_nf2 noop -- --only $s > results/shape$s-2.txt
  sh $H/bench.sh traces/c1.bin $B 7 8 9 shape$s-2-pollute today cand2 cand_nf2 noop -- --only $s --pollute 65536 > results/shape$s-2p.txt
done
taskset -c 12-15 zig build-exe -O ReleaseFast -femit-bin=$H/replay-fast2 $H/replay.zig
sh $H/bench.sh traces/c1.bin $H/replay-fast2 7 8 9 all-fast2 today cand2 cand_nf2 noop > results/all-fast2.txt
for d in cand2 cand_nf2; do taskset -c 8 $B traces/c1.bin $d --mem 2>&1 | grep -E "MEM|RESULT" | sed "s/^/$d /"; done > results/mem2.txt
echo done > results/DONE2
