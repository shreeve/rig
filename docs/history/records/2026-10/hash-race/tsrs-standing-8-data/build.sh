#!/bin/sh
# standing-8's builds: Rig main 1a980833b (with #873, packed small objects),
# ReleaseSafe (build.zig's default), in this folder; then Trig main PGO as
# standing-7's (rig build --release --pgo, trained by tools/trig/bolt-train
# on its own binary). Both through slot.sh on the E-core release slots.
set -u
D=/zfs/worktrees/rig/standing-8; cd $D
export PATH=$HOME/.local/bin:$PATH TRIG_RELEASE_SLOTS="12,13 14,15 16,17"
RC=${RC:-1a980833b}
T=/zfs/trig-pup/full/trig
echo "start $(date +%H:%M)" >> status
if [ ! -x rig/bin/rig ]; then
  rm -rf rig; git -c advice.detachedHead=false clone -q /zfs/trig-pup/rig rig
  (cd rig && git remote set-url origin https://github.com/shreeve/rig.git && git fetch -q origin && git -c advice.detachedHead=false checkout -q --detach $RC)
  (cd rig && sh /zfs/trig-pup/trial/slot.sh zig build -Dnexus=$HOME/Data/Code/nexus/bin/nexus) > rig-build.log 2>&1 \
    && echo "rig built $(date +%H:%M)" >> status || { echo "rig FAILED $(date +%H:%M)" >> status; tail -5 rig-build.log >> status; exit 1; }
fi
git -C $T fetch -q origin
TS=$(git -C $T rev-parse --short origin/main)
echo "rig $(git -C rig rev-parse --short HEAD) trig $TS" > shas.txt
sha256sum rig/bin/rig >> shas.txt
git -C $T log --oneline -15 origin/main > trig-log.txt
rm -rf trig-src; mkdir trig-src; git -C $T archive origin/main | tar -x -C trig-src
s=$D/main; rm -rf $s; mkdir -p $s
cp -a $D/trig-src/src $s/src; cp -a $D/trig-src/tools $s/tools; ln -sfn $T/misc $s/misc; cp $s/tools/trig/main.rig $s/src/main.rig
(cd $s/src && RIG_OUT_DIR=$s/out RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh $D/rig/bin/rig build --release --pgo --pgo-profile=$s/trig.profdata -o $s/bin $s/src/main.rig -- $s/tools/trig/bolt-train $s/bin) > $s/build.log 2>&1 \
  && echo "trig built $(date +%H:%M)" >> status || { echo "trig FAILED $(date +%H:%M)" >> status; tail -5 $s/build.log >> status; }
rm -rf $s/out
echo done >> status
