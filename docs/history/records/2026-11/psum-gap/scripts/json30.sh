#!/bin/bash
set -u
S=/zfs/trig-pup/bin/pup-slot; ST=/zfs/trig-pup/standings-1118; O=/zfs/trig-pup/zfull
exec 9>/tmp/pup-timing.lock; flock -w 7200 9 || { echo "no lock"; exit 1; }
for i in $(seq 360); do $S state | grep -q slot=none && break; sleep 10; done
bash /zfs/trig-pup/runs/timers-clear.sh 25 || { echo "timers"; exit 1; }
: > /zfs/trig-pup/quiet-log/608.txt
o=$($S open 608 25 ab "Zig 0.17.1 JSON rerun, 30 rounds" 2>&1); echo "$o" | tail -n 1; echo "$o" | grep -q "open until" || exit 1
trap '$S close 608 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 608' EXIT
cd $ST/src && taskset -c 8 python3 /zfs/trig-pup/runs/s1118-json-board.py $ST/src/bench/json $ST/json-build 6 30 $O/json30-samples.txt rig-safe,rig-z,rig-aa > $O/json30.txt 2>&1; echo "rc=$?"
tail -16 $O/json30.txt
echo "# done"
