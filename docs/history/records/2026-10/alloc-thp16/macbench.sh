#!/bin/sh
# macbench.sh build | time ROUNDS: bench tasks/actors/net/http (rig-fast)
# with main's rig (main) and the branch's (thp16), interleaved per round.
W=$HOME/Data/Code/worktrees/rig/alloc-thp16
S=${MB:-$(dirname "$0")/mb}
MAIN=$HOME/Data/Code/rig/.git/rig-baseline/967e1ac11331fdeaf4c1dbba192522b92be86364/rig
cmd=$1
if [ $cmd = build ]; then
  for n in main thp16; do
    if [ $n = main ]; then R=$MAIN; else R=$W/bin/rig; fi
    for b in tasks actors net http; do
      mkdir -p $S/$n
      RIG=$R RIG_OUT_DIR=$S/$n/o-$b python3 $W/bench/$b/bench-$b --variants rig-fast --out $S/$n/$b --build-only > $S/$n/build-$b.log 2>&1 || echo "build $n $b failed"
    done
  done
  exit 0
fi
for r in $(seq 1 $2); do
  if [ $((r % 2)) = 0 ]; then order="thp16 main"; else order="main thp16"; fi
  for b in tasks actors net http; do
    for n in $order; do
      echo "== $b $n round $r"
      python3 $W/bench/$b/bench-$b --out $S/$n/$b --time-only --reps 3 --variants rig-fast 2>&1
    done
  done
done
