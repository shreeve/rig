#!/bin/sh
# run-mac.sh: the Mac ceiling, one checker, every arm, shuffled rounds; results to mac-c1.txt.
S=$(cd "$(dirname "$0")/.." && pwd); R=$HOME/Data/Code/worktrees/rig/lazy-table
ARMS="mainbase mainbase2 mainlazy pbbase pblazy pbdefer"
for p in empty:60 mitt:60 neverthrow:60 superstruct:60 ts-pattern:20 zod3:20; do
  while [ -e "$HOME/Data/Code/mumps-compare/.mac-quiet" ]; do sleep 60; done
  "$R/tools/low" python3 "$S/data/bench.py" ${p#*:} 1 ${p%%:*} $ARMS
done
