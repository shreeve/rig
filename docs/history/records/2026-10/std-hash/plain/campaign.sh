#!/bin/sh
# campaign.sh: Trig c75127e's PGO builds, interleaved, fastest of 10, on
# ts-pattern and zod3 at 1 checker (core 8, sibling 9 idle) and 4
# (cores 6-9): base (Trig as is) and h2 (its caches on std.hash) by the
# Rig of the std.hash plain slots, and base2 and h3 the same by that Rig
# with objects of integer parts hashed a pair a multiply.
set -u
cd /zfs/worktrees/rig/std-hash
R=res/c
mkdir -p $R
for p in ts-pattern zod3; do
  for ck in 1 4; do
    sh trigbench.sh $p-c$ck 10 $p $ck warm base-pgo h2-pgo base2-pgo h3-pgo > $R/$p-c$ck.txt
  done
done
echo done > $R/DONE
