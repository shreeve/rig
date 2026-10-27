#!/bin/sh
# hashab.sh ROUNDS: bench/hash of base and new interleaved on core 8, order reversed on even rounds.
export PATH=$HOME/.local/bin:$PATH
L=/zfs/worktrees/rig/bounds-enum
for r in $(seq 1 $1); do
  if [ $((r % 2)) = 0 ]; then order="new base"; else order="base new"; fi
  for n in $order; do echo "== hash $n round $r"; taskset -c 8 python3 $L/rig-$n/bench/hash/bench-hash --out $L/bench/$n/hash --time-only --reps 3 --variants rig-safe,rig-fast 2>&1; done
done
