#!/bin/sh
# phase4.sh: the $plain(K) split (newc, 95a6efd4a) built and timed against
# main (base) and map-inline as it was (new): Trig PGO, spills, bench/hash.
set -u
W=/zfs/worktrees/rig/map-inline
cd $W
R=res4
mkdir -p $R
export QLOG=$W/$R/quiet.log
(cd newc && NEXUS=/zfs/rig/nexus/bin/nexus nice zig build > ../build-newc.log 2>&1)
sh buildtrig.sh $W/newc/bin/rig newc-pgo pgo
mkdir -p hash/newc
RIG=$W/newc/bin/rig sh /zfs/trig-pup/trial/slot.sh python3 $W/newc/bench/hash/bench-hash --variants rig-safe,rig-fast --out $W/hash/newc --build-only > hash/build-newc.log 2>&1
for p in ts-pattern zod3; do
  for ck in 1 4; do
    for mode in warm cold; do
      sh quiet.sh; sh trigbench.sh pgo-$p-c$ck-$mode 10 $p $ck $mode base-pgo new-pgo newc-pgo > $R/pgo-$p-c$ck-$mode.txt
    done
  done
done
sh quiet.sh; sh hashbench.sh 21 hash/base/rig-safe hash/new/rig-safe hash/newc/rig-safe hash/base/rig-fast hash/new/rig-fast hash/newc/rig-fast > $R/hash.txt 2>&1
i=$(python3 -c "import re;f=open(\"$R/pgo-ts-pattern-c1-warm.txt\").read();print(min(int(x) for x in re.findall(r\"build=newc-pgo cycles=\\d+ instructions=(\\d+)\",f)))")
sh quiet.sh; INSTR=$i sh spillrun.sh newc-pgo 30 > $R/spills-newc-pgo.txt 2>&1
sh whole.sh newc-pgo $W/newc/src $i > $R/whole-newc-pgo.txt 2>&1
for k in 1 2 3; do for b in base-pgo new-pgo newc-pgo; do for p in ts-pattern zod3; do echo "$b $p $(sh rsssplit.sh $b $p)"; done; done; done > $R/rsssplit.txt
echo done > $R/DONE
