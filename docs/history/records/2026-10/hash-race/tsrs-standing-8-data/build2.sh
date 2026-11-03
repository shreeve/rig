#!/bin/sh
# standing-8's Trig builds, after build.sh built Rig main 1a980833b here:
# Trig main PGO as tools/trig/pgo builds it (main: CHECK_IDS false, the
# bench's build) and as standing-7's build.sh did (ids: CHECK_IDS true),
# each trained by tools/trig/bolt-train on its own binary, through slot.sh
# on the E-core release slots, side by side.
set -u
D=/zfs/worktrees/rig/standing-8; cd $D
export PATH=$HOME/.local/bin:$PATH TRIG_RELEASE_SLOTS="12,13 14,15 16,17"
T=/zfs/trig-pup/full/trig
W=${1:-}; n=0  # wait for build.sh's Rig build (its release-slot pid) to end, at most 15 min
while [ -n "$W" ] && kill -0 $W 2>/dev/null && [ $n -lt 900 ]; do sleep 5; n=$((n + 5)); done
[ -x rig/bin/rig ] && echo "rig built $(date +%H:%M)" >> status || { echo "rig MISSING $(date +%H:%M)" >> status; exit 1; }
git -C $T fetch -q origin
TS=$(git -C $T rev-parse --short origin/main)
echo "rig $(git -C rig rev-parse --short HEAD) trig $TS" > shas.txt
sha256sum rig/bin/rig >> shas.txt
git -C $T log --oneline -15 origin/main > trig-log.txt
rm -rf trig-src; mkdir trig-src; git -C $T archive origin/main | tar -x -C trig-src
build() { # build NAME
  s=$D/$1; rm -rf $s; mkdir -p $s
  cp -a $D/trig-src/src $s/src; cp -a $D/trig-src/tools $s/tools; ln -sfn $T/misc $s/misc; cp $s/tools/trig/main.rig $s/src/main.rig
  if [ $1 = main ]; then
    sed -i 's/^pub CHECK_IDS = true$/pub CHECK_IDS = false/' $s/src/checks/checks.rig
    grep -q '^pub CHECK_IDS = false$' $s/src/checks/checks.rig || { echo "main: CHECK_IDS not set" >> $D/status; return; }
  fi
  (cd $s/src && RIG_OUT_DIR=$s/out RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh $D/rig/bin/rig build --release --pgo --pgo-profile=$s/trig.profdata -o $s/bin $s/src/main.rig -- $s/tools/trig/bolt-train $s/bin) > $s/build.log 2>&1 \
    && echo "$1 built $(date +%H:%M)" >> $D/status || { echo "$1 FAILED $(date +%H:%M)" >> $D/status; tail -5 $s/build.log >> $D/status; }
  rm -rf $s/out
}
build main & a=$!
sleep 30
build ids & b=$!
wait $a $b
echo done >> status
