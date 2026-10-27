#!/bin/sh
# macbench.sh build | time ROUNDS: bench tasks/actors/net/http (rig-fast)
# with main's rig (base) and the branch's (reuse), interleaved per round.
W=$HOME/Data/Code/worktrees/rig/alloc-large
S=$(dirname "$0")/mb
BASE=$HOME/Data/Code/rig/.git/rig-baseline/54a7158b54e788ec221a05b4fab7685970682093/rig
cmd=$1
if [ $cmd = build ]; then
  for n in base reuse; do
    if [ $n = base ]; then R=$BASE; else R=$W/bin/rig; fi
    for b in tasks actors net http; do
      mkdir -p $S/$n
      RIG=$R RIG_OUT_DIR=$S/$n/o-$b python3 $W/bench/$b/bench-$b --variants rig-fast --out $S/$n/$b --build-only > $S/$n/build-$b.log 2>&1 || echo "build $n $b failed"
    done
  done
  exit 0
fi
for r in $(seq 1 $2); do
  if [ $((r % 2)) = 0 ]; then order="reuse base"; else order="base reuse"; fi
  for b in tasks actors net http; do
    for n in $order; do
      echo "== $b $n round $r"
      python3 $W/bench/$b/bench-$b --out $S/$n/$b --time-only --reps 3 --variants rig-fast 2>&1
    done
  done
done
