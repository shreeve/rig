#!/bin/sh
# The measurement: real Trig at one checker, then the replay, on core 8 (sibling 9 idle).
set -u
cd /zfs/worktrees/rig/map-replay/.replay
H=harness
# 1. Trig itself, fastest of 11.
for r in $(seq 1 11); do
  (cd run1/ts-pattern && perf stat -x, -e cpu_core/cycles/u,cpu_core/instructions/u -o ../../results/trig-perf-$r.txt taskset -c 8 ../../pack-plain/bin -p tsconfig.trig.json --noEmit --singleThreaded > /dev/null 2>&1)
done
# 2. The whole replay, safe build (Trig is built --release, Zig safe mode).
sh $H/bench.sh traces/c1.bin $H/replay-safe 11 8 9 all-safe today today_nf cand cand_nf cand_nf_sh cand_nf_ph noop > results/all-safe.txt
# 3. Each hot shape alone.
for s in 0 1 2 3 4 6 7; do
  sh $H/bench.sh traces/c1.bin $H/replay-safe 11 8 9 shape$s today today_nf cand cand_nf cand_nf_sh noop -- --only $s > results/shape$s.txt
done
# 4. With a 64 MiB buffer read between operations (a colder cache).
sh $H/bench.sh traces/c1.bin $H/replay-safe 11 8 9 pollute64M today cand cand_nf cand_nf_sh noop -- --pollute 65536 > results/pollute.txt
# 5. Zig fast mode.
sh $H/bench.sh traces/c1.bin $H/replay-fast 7 8 9 all-fast today today_nf cand cand_nf cand_nf_sh noop > results/all-fast.txt
# 6. Memory.
for d in today today_nf cand cand_nf cand_nf_sh; do taskset -c 8 $H/replay-safe traces/c1.bin $d --mem 2>&1 | grep -E "MEM|RESULT" | sed "s/^/$d /"; done > results/mem.txt
echo done > results/DONE
