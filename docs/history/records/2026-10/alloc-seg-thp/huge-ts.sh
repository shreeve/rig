#!/bin/sh
# huge-ts.sh: tsrs-standing-data/huge.sh on this record's builds: peak
# RSS and its share in huge pages, from /proc/PID/smaps_rollup sampled
# about every 10 ms by a poller on E-core 12 while the program runs on
# core 6 (--singleThreaded). Three runs per variant; each line is the
# sample of largest Rss.
set -u
A=/zfs/worktrees/rig/alloc-seg-thp
P=/zfs/trig-pup/full/trig/misc/projects
for proj in ts-pattern zod3; do
  cd $P/$proj
  for i in 1 2 3; do
    for v in main seg segnp seglead tbl; do
      taskset -c 6 $A/trig-$v/bin -p tsconfig.trig.json --noEmit --singleThreaded > /dev/null 2>&1 &
      pid=$!
      best=0 hp=0
      while s=$(taskset -c 12 awk '/^Rss:/ { r = $2 } /^AnonHugePages:/ { h = $2 } END { if (r) print r, h }' /proc/$pid/smaps_rollup 2>/dev/null) && [ -n "$s" ]; do
        set -- $s
        [ $1 -gt $best ] && { best=$1; hp=$2; }
        sleep 0.01
      done
      wait $pid
      echo "$proj run=$i v=$v rss_kb=$best anonhuge_kb=$hp"
    done
  done
done
