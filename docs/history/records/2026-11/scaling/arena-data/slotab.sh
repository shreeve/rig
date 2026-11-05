#!/bin/sh
# slotab.sh NN MIN ROUNDS TAG ARM=BIN...: one timing slot for an A/B of Trig binaries.
set -u
D=/zfs/rig-work/scaling; NN=$1; M=$2; N=$3; TAG=$4; shift 4
sh /tmp/open-slot.sh $NN $M >> $D/run-status 2>&1
rm -rf /tmp/scal-ab; mkdir -p /tmp/scal-ab; ARMS=""
for ab in "$@"; do a=${ab%%=*}; cp ${ab#*=} /tmp/scal-ab/$a; ARMS="$ARMS $a"; done
echo "$TAG start $(date +%T) load $(cut -d' ' -f1-3 /proc/loadavg)" >> $D/run-status
timeout $(( M * 60 - 20 )) bash $D/${SCRIPT:-ab.sh} $N $D/$TAG $ARMS; echo "$TAG end $(date +%T) exit $? load $(cut -d' ' -f1-3 /proc/loadavg)" >> $D/run-status
rm -rf /tmp/scal-ab
rm -f /tmp/slot-active; for p in $(cat /tmp/quiet-pids$NN); do kill -CONT $p 2>/dev/null; done
echo "slot closed $(date +%T)" >> $D/run-status
