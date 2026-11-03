#!/bin/sh
# slot.sh NN ROUNDS PROJECTS TAG: one <=10-minute timing slot for standing-8:
# open the slot, copy the binaries to tmpfs, time-ab.sh with a hard cap,
# remove the copies, close the slot.
set -u
D=/zfs/worktrees/rig/standing-8; NN=$1; N=$2; PROJS=$3; TAG=$4
sh /tmp/open-slot.sh $NN 10 >> $D/run-status 2>&1
rm -rf /tmp/s8; mkdir -p /tmp/s8; cp $D/bin/trig $D/bin/aa $D/bin/ids /tmp/s8/; cp -a $D/bin/tsrs /tmp/s8/tsrs
echo "$TAG start $(date +%T)" >> $D/run-status
S8W=$D/$TAG timeout 570 sh /zfs/trig-pup/trial/time-ab.sh $D/s8.conf $N "$PROJS" > $D/times-$TAG.txt 2>&1
echo "$TAG end $(date +%T) exit $?" >> $D/run-status
rm -rf /tmp/s8
rm -f /tmp/slot-active; for p in $(cat /tmp/quiet-pids$NN); do kill -CONT $p; done
echo "$TAG slot closed $(date +%T)" >> $D/run-status
