#!/bin/sh
# phase3.sh: newb-pgo (find unmarked, insert inlined) built, then the PGO
# builds timed again on a quiet pup: base-pgo, new-pgo, newb-pgo.
set -u
cd /zfs/worktrees/rig/map-inline
R=res3
mkdir -p $R
until [ -f res/DONE-all ]; do sleep 30; done
sh quiet.sh
sh buildtrig.sh /zfs/worktrees/rig/map-inline/newb/bin/rig newb-pgo pgo
for p in ts-pattern zod3; do
  for ck in 1 4; do
    for mode in warm cold; do
      sh quiet.sh; sh trigbench.sh pgo-$p-c$ck-$mode 10 $p $ck $mode base-pgo new-pgo newb-pgo > $R/pgo-$p-c$ck-$mode.txt
    done
  done
done
echo done > $R/DONE
