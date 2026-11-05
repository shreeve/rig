#!/bin/sh
# abslot.sh NN MIN ROUNDS name=BIN...: one timing slot for abn3.sh, the binaries copied to tmpfs for it,
# the free 2 MiB blocks logged at its start and end.
set -u
E=/zfs/rig-work/scaling/eh; NN=$1; M=$2; N=$3; shift 3
sh /tmp/open-slot.sh $NN $M >> $E/run-status 2>&1
mkdir -p /tmp/rw-ab; arms=""
for a in "$@"; do n=${a%%=*}; cp "${a#*=}" /tmp/rw-ab/$n; arms="$arms $n=/tmp/rw-ab/$n"; done
echo "ab start $(date +%T) free2M $(awk '/Normal/{print $14 + 2 * $15}' /proc/buddyinfo) load $(cut -d' ' -f1-3 /proc/loadavg)" >> $E/run-status
timeout $(( M * 60 - 45 )) bash $E/abn3.sh $E/ab4.txt $N $arms; echo "ab end $(date +%T) exit $? free2M $(awk '/Normal/{print $14 + 2 * $15}' /proc/buddyinfo) load $(cut -d' ' -f1-3 /proc/loadavg)" >> $E/run-status
for a in "$@"; do rm -f /tmp/rw-ab/${a%%=*}; done; rmdir /tmp/rw-ab
rm -f /tmp/slot-active; for p in $(cat /tmp/quiet-pids$NN); do kill -CONT $p 2>/dev/null; done
echo "slot closed $(date +%T)" >> $E/run-status
