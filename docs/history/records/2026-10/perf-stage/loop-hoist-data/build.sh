#!/bin/sh
# build.sh NAME RIG MODE: build trig (lh/trig, Trig main) with RIG into lh/NAME/bin;
# MODE release or pgo (trained by tools/trig/bolt-train, as tools/trig/pgo does).
set -e
name=$1; rig=$2; mode=$3
top=/zfs/trig-pup/trial/lh/trig
d=/zfs/trig-pup/trial/lh/$name
rm -rf $d; mkdir -p $d/src
for m in $top/src/*/; do cp -a $m $d/src/; done
cp $top/tools/trig/main.rig $d/src/main.rig
export PATH=$HOME/.local/bin:$PATH
cd $d/src
if [ $mode = pgo ]; then
  RIG_OUT_DIR=$d/out RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh $rig build --release --pgo --pgo-profile=$d/trig.profdata -o $d/bin $d/src/main.rig -- $top/tools/trig/bolt-train $d/bin > $d/build.log 2>&1
else
  RIG_OUT_DIR=$d/out RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh $rig build --release -o $d/bin $d/src/main.rig > $d/build.log 2>&1
fi
echo built $d/bin
