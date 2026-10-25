#!/bin/sh
# benches.sh ROUNDS: bench/tasks, actors, net and http (rig-fast) of main and the change, pinned to cores 6 and 7, interleaved
P=/zfs/worktrees/rig/prefault-large
export PATH=$HOME/.local/go/bin:$PATH
for r in $(seq 1 $1); do
  for b in tasks actors net http; do
    for v in main fix; do
      echo "== $b $v round $r (load $(cut -d' ' -f1 /proc/loadavg))"; (cd $P/$v && taskset -c 6,7 python3 bench/$b/bench-$b --variants rig-fast --time-only --out $P/b$b-$v 2>&1)
    done
  done
done
echo DONE
