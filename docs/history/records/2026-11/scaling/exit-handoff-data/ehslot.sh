#!/bin/sh
# ehslot.sh NN MIN ROUNDS: one slot for ehab.sh, the binary on tmpfs for the slot only.
set -u
D=/zfs/rig-work/scaling/eh; NN=$1; M=$2; N=$3
sh /tmp/open-slot.sh $NN $M >> $D/run-status 2>&1
mkdir -p /tmp/rw-eh
cp /zfs/trig-pup/runs/eq-new/.zig-cache/trig-tests/packs/trig-pgo/bin /tmp/rw-eh/trig
echo "start $(date +%T) load $(cut -d' ' -f1-3 /proc/loadavg)" >> $D/run-status
timeout $(( M * 60 - 30 )) bash $D/ehab.sh $D/ab.txt $N; echo "end $(date +%T) exit $? load $(cut -d' ' -f1-3 /proc/loadavg)" >> $D/run-status
rm -f /tmp/rw-eh/trig; rmdir /tmp/rw-eh
rm -f /tmp/slot-active; for p in $(cat /tmp/quiet-pids$NN); do kill -CONT $p 2>/dev/null; done
echo "slot closed $(date +%T)" >> $D/run-status
