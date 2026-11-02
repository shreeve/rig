#!/bin/sh
# standing-7's two Trig builds, PGO as standing-6's: Trig main as it stands
# (main) and the same with lib.esnext.d.ts's three references tsrs 0.18.0's
# lacks removed (nolib3: esnext.iterator, .modulesource, .promise), each
# trained on its own binary by tools/trig/bolt-train. Rig is the full
# suite's ReleaseSafe build of e10087dd8, whose sources match Rig main
# 5e2dd0d7a (#866 changed records only), copied here. Both builds through
# slot.sh on the E-core release slots, side by side (slot.sh lets two run).
set -u
D=/zfs/worktrees/rig/standing-7; mkdir -p $D; cd $D
export PATH=$HOME/.local/bin:$PATH TRIG_RELEASE_SLOTS="12,13 14,15 16,17"
T=/zfs/trig-pup/full/trig
echo "start $(date +%H:%M)" >> status
git -C $T fetch -q origin
TS=$(git -C $T rev-parse --short origin/main)
mkdir -p rig/bin; cp /zfs/trig-pup/full/rig/bin/rig rig/bin/rig
RS=$(cat /zfs/trig-pup/full/rig.built)
echo "rig $RS trig $TS" > shas.txt
sha256sum rig/bin/rig >> shas.txt
git -C $T log --oneline -15 origin/main > trig-log.txt
rm -rf trig-src; mkdir trig-src; git -C $T archive origin/main | tar -x -C trig-src
build() { # build NAME
  s=$D/$1; rm -rf $s; mkdir -p $s
  cp -a $D/trig-src/src $s/src; cp -a $D/trig-src/tools $s/tools; ln -sfn $T/misc $s/misc; cp $s/tools/trig/main.rig $s/src/main.rig
  if [ $1 = nolib3 ]; then
    for l in iterator modulesource promise; do
      sed -i "s|/// <reference lib=\\\\\"esnext\\.$l\\\\\" />\\\\n||" $s/src/bundled/embed_generated.rig
    done
    diff $D/trig-src/src/bundled/embed_generated.rig $s/src/bundled/embed_generated.rig | wc -c > $s/patch-bytes
  fi
  (cd $s/src && RIG_OUT_DIR=$s/out RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh $D/rig/bin/rig build --release --pgo --pgo-profile=$s/trig.profdata -o $s/bin $s/src/main.rig -- $s/tools/trig/bolt-train $s/bin) > $s/build.log 2>&1 && echo "$1 built $(date +%H:%M)" >> $D/status || { echo "$1 FAILED $(date +%H:%M)" >> $D/status; tail -5 $s/build.log >> $D/status; }
  rm -rf $s/out
}
build main & a=$!
sleep 30
build nolib3 & b=$!
wait $a $b
echo done >> status
