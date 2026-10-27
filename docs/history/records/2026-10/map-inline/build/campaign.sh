#!/bin/sh
# campaign.sh: map-inline against Rig main on Trig main (c75127e):
# release and PGO, ts-pattern and zod3 at 1 and 4 checkers, warm and
# cold, fastest of 10 interleaved; then the PGO spills; bench/hash; std.json.
set -u
cd /zfs/worktrees/rig/map-inline
R=res
mkdir -p $R
for p in ts-pattern zod3; do
  for ck in 1 4; do
    for mode in warm cold; do
      sh quiet.sh; sh trigbench.sh $p-c$ck-$mode 10 $p $ck $mode base new newb > $R/$p-c$ck-$mode.txt
      sh quiet.sh; sh trigbench.sh pgo-$p-c$ck-$mode 10 $p $ck $mode base-pgo new-pgo > $R/pgo-$p-c$ck-$mode.txt
    done
  done
done
echo trig > $R/DONE-trig
