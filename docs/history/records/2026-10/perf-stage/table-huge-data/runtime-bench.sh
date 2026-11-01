#!/bin/sh
# bench.sh build | time ROUNDS: AGENTS' runtime benches (bench/tasks,
# actors, net, http; rig-fast) for main and the seg branch.
#   build: each with its own Rig, on cores 6,7.
#   time:  the two builds interleaved in each round (order reversed on
#          even rounds), 3 reps a run, pinned to P-core 6 and its
#          sibling 7; the fastest of all counts (benchsum.py).
export PATH=$HOME/.local/go/bin:$HOME/.local/bin:$PATH XDG_CACHE_HOME=/zfs/rig/xdg-cache
A=/zfs/worktrees/rig/seg-bench
rig_of() { case $1 in main) echo /zfs/worktrees/rig/seg-bench/rig-main ;; seg) echo /zfs/worktrees/rig/seg-bench/rig-seg ;; esac; }
names="main seg"
cmd=$1; shift
if [ $cmd = build ]; then
  for n in $names; do
    R=$(rig_of $n); mkdir -p $A/bench/$n
    for b in tasks actors net http; do
      RIG=$R/bin/rig RIG_OUT_DIR=$A/bench/$n/o-$b taskset -c 6,7 python3 $R/bench/$b/bench-$b --variants rig-fast --out $A/bench/$n/$b --build-only > $A/bench/$n/build-$b.log 2>&1 || echo "build $n $b failed"
    done
    echo "built benches $n"
  done
  exit 0
fi
rounds=$1
rev="seg main"
for r in $(seq 1 $rounds); do
  if [ $((r % 2)) = 0 ]; then order=$rev; else order=$names; fi
  for b in tasks actors net http; do
    for n in $order; do
      R=$(rig_of $n)
      echo "== $b $n round $r"
      RIG=$R/bin/rig taskset -c 6,7 python3 $R/bench/$b/bench-$b --out $A/bench/$n/$b --time-only --reps 3 --variants rig-fast 2>&1
    done
  done
done
