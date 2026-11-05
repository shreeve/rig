#!/bin/sh
# slotp.sh NN MIN TAG: one slot for the profiles (prof.sh).
set -u
D=/zfs/rig-work/scaling; NN=$1; M=$2; TAG=$3
sh /tmp/open-slot.sh $NN $M >> $D/run-status 2>&1
rm -rf /tmp/scal-probe; mkdir -p /tmp/scal-probe
cp /zfs/trig-pup/runs/eq-new/.zig-cache/trig-tests/packs/trig-pgo/bin /tmp/scal-probe/trig
cp -a /zfs/trig-pup/tsrs-shipped/package /tmp/scal-probe/tsrs
echo "prof start $(date +%T) load $(cut -d' ' -f1-3 /proc/loadavg)" >> $D/run-status
timeout $(( M * 60 - 30 )) bash $D/${SCRIPT:-prof.sh} $D/$TAG; echo "prof end $(date +%T) exit $? load $(cut -d' ' -f1-3 /proc/loadavg)" >> $D/run-status
cp /tmp/scal-probe/trig $D/$TAG/trig.bin 2>/dev/null
rm -rf /tmp/scal-probe
rm -f /tmp/slot-active; for p in $(cat /tmp/quiet-pids$NN); do kill -CONT $p 2>/dev/null; done
echo "slot closed $(date +%T)" >> $D/run-status
