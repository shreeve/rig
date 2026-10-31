#!/bin/bash
# slot2.sh: Trig (main vs a, six projects, 21 rounds), then kv64k/xmalloc/sh8bench on the
# PR's base (main2 = 144f70057 vs pr = the PR head, 10 rounds), then the runtime benches
# (main2 vs pr alternated, two passes, core 6).
W=/zfs/worktrees/rig/mem-both
export PATH=$HOME/.local/share/mise/shims:$PATH
cd $W
echo "trig start $(date +%T)"; bash trigtime.sh 21 main a > trig2.txt 2>&1
echo "kv start $(date +%T)"; ONLY64=1 bash run.sh 10 main2 pr > results3.txt 2>&1
echo "bench start $(date +%T)"
cd $W/rig-pr
for b in tasks actors net http; do
  for pass in 1 2; do
    for v in main2 pr; do
      echo "== $b $v pass $pass"
      RIG=$W/rig-$v/bin/rig taskset -c 6 python3 bench/$b/bench-$b --variants rig-fast --reps 5 2>&1 | tail -8
      [ $b = http ] && sleep 40
    done
  done
done > $W/bench2.txt 2>&1
echo "done $(date +%T)"
