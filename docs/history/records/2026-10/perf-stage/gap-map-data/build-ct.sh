#!/bin/sh
# Counting copy: build once (keeping the emitted Zig in /tmp/gm2/bct/out)
R=/zfs/trig-pup/full/rig/bin/rig; S=/tmp/gm2/src-ct; d=/tmp/gm2/bct
rm -rf $d; mkdir -p $d/pack $d/out
for m in $S/src/*; do ln -s $m $d/pack/$(basename $m); done
ln -s $S/tools/trig/main.rig $d/pack/main.rig
cd $d/pack && RIG_OUT_DIR=$d/out sh /zfs/trig-pup/trial/slot.sh $R build --release -o /tmp/gm2/ct0 main.rig > /tmp/gm2/build-ct.log 2>&1
echo "exit $?" >> /tmp/gm2/build-ct.log
