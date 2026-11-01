#!/bin/sh
# rbench.sh build | time ROUNDS: the runtime benches (bench/tasks, actors,
# net, http; rig-fast) for base (Rig a5a78efbb, alloc.zig and table.zig as
# main) and fix2 (#832). build: on E-cores 18,19. time: interleaved, order
# reversed on even rounds, 3 reps a run, on P-core 6 and its sibling 7.
export PATH=$HOME/.local/go/bin:$HOME/.local/bin:$PATH XDG_CACHE_HOME=/zfs/rig/xdg-cache
A=/zfs/worktrees/rig/item15
names="base fix2"
cmd=$1; shift
if [ $cmd = build ]; then
  for n in $names; do
    R=$A/$n; mkdir -p $A/bench/$n
    for b in tasks actors net http; do
      RIG=$R/bin/rig RIG_OUT_DIR=$A/bench/$n/o-$b taskset -c 18,19 python3 $R/bench/$b/bench-$b --variants rig-fast --out $A/bench/$n/$b --build-only > $A/bench/$n/build-$b.log 2>&1 || echo "build $n $b failed"
    done
    echo "built benches $n"
  done
  exit 0
fi
rounds=$1
for r in $(seq 1 $rounds); do
  if [ $((r % 2)) = 0 ]; then order="fix2 base"; else order=$names; fi
  for b in tasks actors net http; do
    for n in $order; do
      echo "== $b $n round $r"
      RIG=$A/$n/bin/rig taskset -c 6,7 python3 $A/$n/bench/$b/bench-$b --out $A/bench/$n/$b --time-only --reps 3 --variants rig-fast 2>&1
    done
  done
done
echo "# done $(date +%T)"
