#!/bin/sh
# rsssplit.sh BUILD PROJECT: peak RssAnon and RssFile (KB), sampled every 2 ms from /proc, one checker on core 8.
W=/zfs/worktrees/rig/map-inline
cd $W/trig/misc/projects/$2
taskset -c 8 $W/packs/$1/bin -p tsconfig.trig.json --noEmit --singleThreaded > /dev/null 2>&1 &
p=$!
a=0; f=0
while kill -0 $p 2>/dev/null; do
  set -- $(awk "/RssAnon|RssFile/ {print \$2}" /proc/$p/status 2>/dev/null) 0 0
  [ "$1" -gt "$a" ] && a=$1; [ "$2" -gt "$f" ] && f=$2
  sleep 0.002
done
echo "anon_kb=$a file_kb=$f"
