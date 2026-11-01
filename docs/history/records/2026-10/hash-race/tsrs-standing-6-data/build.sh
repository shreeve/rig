#!/bin/sh
# st6-build.sh: standing-6's Trig, PGO-built from Trig main by Rig main (928b44bf2 or newer), on the E-core release slots, once the sched-wake rerun's last build is done.
set -u
D=/zfs/worktrees/rig/standing-6; mkdir -p $D; cd $D
export PATH=$HOME/.local/bin:$PATH NEXUS=/zfs/rig/nexus/bin/nexus TRIG_RELEASE_SLOTS="12,13 14,15 16,17"
n=0
until grep -q done2 /zfs/worktrees/rig/sched-wake2/trig-status 2>/dev/null; do n=$((n+1)); [ $n -gt 600 ] && { echo "gave up waiting $(date +%H:%M)" >> status; exit 1; }; sleep 20; done
echo "start $(date +%H:%M)" >> status
R=/zfs/trig-pup/full/rig; T=/zfs/trig-pup/full/trig
git -C $R fetch -q origin; git -C $T fetch -q origin
RS=$(git -C $R rev-parse --short origin/main); TS=$(git -C $T rev-parse --short origin/main)
git -C $R merge-base --is-ancestor 928b44bf2 origin/main || { echo "rig $RS lacks 928b44bf2 FAILED" >> status; exit 1; }
echo "rig $RS trig $TS" > shas.txt
git -C $T log --oneline -15 origin/main > trig-log.txt
if [ ! -x rig/bin/rig ]; then
  rm -rf rig; mkdir rig; git -C $R archive origin/main | tar -x -C rig
  (cd rig && sh /zfs/trig-pup/trial/slot.sh zig build -Dnexus=$NEXUS) > build-rig.log 2>&1 || { echo "rig FAILED $(date +%H:%M)" >> status; exit 1; }
fi
echo "rig built $(date +%H:%M)" >> status
s=$D/trig; rm -rf $s $D/trig-src; mkdir -p $s $D/trig-src
git -C $T archive origin/main | tar -x -C $D/trig-src
cp -a $D/trig-src/src $s/src; cp -a $D/trig-src/tools $s/tools; ln -sfn $T/misc $s/misc; cp $s/tools/trig/main.rig $s/src/main.rig
(cd $s/src && RIG_OUT_DIR=$s/out RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh $D/rig/bin/rig build --release --pgo --pgo-profile=$s/trig.profdata -o $s/bin $s/src/main.rig -- $s/tools/trig/bolt-train $s/bin) > $s/build.log 2>&1 && echo "trig built $(date +%H:%M)" >> status || { echo "trig FAILED $(date +%H:%M)" >> status; tail -5 $s/build.log >> status; }
rm -rf $s/out
echo done >> status
