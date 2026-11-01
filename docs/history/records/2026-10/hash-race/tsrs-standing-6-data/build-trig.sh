#!/bin/sh
# st6-trig.sh: standing-6's Trig again at 806e0a109 (trig#231, the parser), PGO by the Rig already built beside it, on the E-core release slots.
set -u
D=/zfs/worktrees/rig/standing-6; cd $D
export PATH=$HOME/.local/bin:$PATH TRIG_RELEASE_SLOTS="12,13 14,15 16,17"
T=/zfs/trig-pup/full/trig
git -C $T fetch -q origin
TS=$(git -C $T rev-parse --short origin/main)
git -C $T merge-base --is-ancestor 806e0a109 origin/main || { echo "trig $TS lacks 806e0a109 FAILED" >> status; echo done2 >> status; exit 1; }
RS=$(awk '{print $2}' shas.txt)
echo "rig $RS trig $TS" > shas.txt
git -C $T log --oneline -15 origin/main > trig-log.txt
echo "trig rebuild at $TS $(date +%H:%M)" >> status
s=$D/trig; rm -rf $s $D/trig-src; mkdir -p $s $D/trig-src
git -C $T archive origin/main | tar -x -C $D/trig-src
cp -a $D/trig-src/src $s/src; cp -a $D/trig-src/tools $s/tools; ln -sfn $T/misc $s/misc; cp $s/tools/trig/main.rig $s/src/main.rig
(cd $s/src && RIG_OUT_DIR=$s/out RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh $D/rig/bin/rig build --release --pgo --pgo-profile=$s/trig.profdata -o $s/bin $s/src/main.rig -- $s/tools/trig/bolt-train $s/bin) > $s/build.log 2>&1 && echo "trig built $(date +%H:%M)" >> status || { echo "trig FAILED $(date +%H:%M)" >> status; tail -5 $s/build.log >> status; }
rm -rf $s/out
echo done2 >> status
