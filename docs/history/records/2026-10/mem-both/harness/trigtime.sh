#!/bin/bash
# trigtime.sh ROUNDS ARM...: Trig (packs/ARM-pgo/bin) on ts-pattern and zod3,
# one checker, pinned to P-core 3 (its sibling 4 idle), arms interleaved and
# the first rotated each round. Lines: ROUND ARM PROJECT wall_s maxrss_kb.
W=/zfs/worktrees/rig/mem-both
rounds=$1; shift; arms=("$@"); n=${#arms[@]}
for r in $(seq $rounds); do
  for proj in ts-pattern zod3; do
    cd $W/trig/misc/projects/$proj
    for k in $(seq 0 $((n-1))); do
      arm=${arms[$(( (k + r - 1) % n ))]}
      taskset -c 3 /usr/bin/time -f "%e %M" -o $W/tt.out $W/packs/$arm-pgo/bin -p tsconfig.trig.json --noEmit --singleThreaded > /dev/null 2>&1
      echo "$r $arm $proj $(cat $W/tt.out)"
    done
  done
done
