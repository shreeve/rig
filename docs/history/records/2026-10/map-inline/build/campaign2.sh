#!/bin/sh
set -u
W=/zfs/worktrees/rig/map-inline
cd $W
R=res
until [ -f $R/DONE-trig ]; do sleep 30; done
for b in base-pgo new-pgo; do
  i=$(python3 -c "import re;f=open(\"$R/pgo-ts-pattern-c1-warm.txt\").read();print(min(int(x) for x in re.findall(r\"build=$b cycles=\\d+ instructions=(\\d+)\",f)))")
  sh quiet.sh; INSTR=$i sh spillrun.sh $b 30 > $R/spills-$b.txt 2>&1
  sh whole.sh $b $W/new/src $i > $R/whole-$b.txt 2>&1
done
sh quiet.sh; sh score-mi.sh 10 ts-pattern zod3 > $R/score.txt 2>&1
sh quiet.sh; sh hashbench.sh 11 hash/base/rig-safe hash/new/rig-safe hash/base/rig-fast hash/new/rig-fast > $R/hash.txt 2>&1
sh quiet.sh; python3 jsonbench.py 11 > $R/json.txt 2>&1
echo done > $R/DONE-all
