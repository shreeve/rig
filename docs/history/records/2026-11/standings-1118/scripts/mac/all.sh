#!/bin/bash
# all.sh ROW...: each row in its own claim, one after the other; waits for .mac-quiet to go (bounded).
B=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/fb
Q=~/Data/Code/mumps-compare/.mac-quiet
for b in "$@"; do
  n=0; while [ -e $Q ] && [ $n -lt 180 ]; do sleep 10; n=$((n+1)); done
  [ -e $Q ] && { echo "$b: .mac-quiet still there after 30 min, stop"; exit 1; }
  echo "$b requested $(date +%H:%M:%S)"
  /Users/shreeve/Data/Code/worktrees/rig/m11/tools/mac-claim --minutes 18 fb-$b $B/job.sh $b > $B/c-$b.log 2>&1
  echo "$b rc=$? $(date +%H:%M:%S)"
done
echo ALL-DONE
