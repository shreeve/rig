#!/bin/sh
# campaign3.sh: Trig main built by Rig main (base) and by map-stage at
# 01fc95ba2 (final3), release and PGO, on ts-pattern and zod3 at 1 and 4
# checkers, warm and cold, fastest of 10 interleaved; the other light-gate
# projects at one checker; then bench/hash and std.json.
set -u
cd /zfs/worktrees/rig/map-stage
R=res/e
mkdir -p $R
for p in ts-pattern zod3; do
  for ck in 1 4; do
    for mode in warm cold; do
      sh trigbench.sh $p-c$ck-$mode 10 $p $ck $mode base final3 > $R/$p-c$ck-$mode.txt
      sh trigbench.sh pgo-$p-c$ck-$mode 10 $p $ck $mode base-pgo final3-pgo > $R/pgo-$p-c$ck-$mode.txt
    done
  done
done
for p in tiny-invariant superstruct mitt neverthrow; do
  sh trigbench.sh $p-c1-warm 10 $p 1 warm base final3 > $R/$p-c1-warm.txt
  sh trigbench.sh pgo-$p-c1-warm 10 $p 1 warm base-pgo final3-pgo > $R/pgo-$p-c1-warm.txt
done
sh hashbench.sh 11 hash/base-safe hash/new-safe hash/base-fast hash/new-fast > $R/hash.txt 2>&1
python3 jsonbench.py 11 > $R/json.txt 2>&1
echo done > $R/DONE
