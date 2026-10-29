#!/bin/sh
# On pup: benchtime.sh B...: each concurrency bench's rig-fast and rig-safe
# builds of Rig main and the branch, timed on cores 6,7 only, main and
# branch alternating, two rounds each (each round the bench's own best of
# its reps).
W=/zfs/worktrees/rig/runtime-unchecked
export PATH=/home/shreeve/.local/share/mise/installs/go/1.27.2/bin:$PATH
for b in "$@"; do
  for r in 1 2; do
    for side in main branch; do
      echo "== $b round $r $side $(date +%T) load=$(cut -d' ' -f1 /proc/loadavg)"
      (cd $W/rig && taskset -c 6,7 python3 bench/$b/bench-$b --variants rig-fast,rig-safe --out $W/bench-out/$side/$b --time-only 2>&1)
    done
  done
done
