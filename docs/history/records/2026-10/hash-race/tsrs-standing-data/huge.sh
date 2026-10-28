#!/bin/sh
# On pup: peak RSS and its share in huge pages, from /proc/PID/smaps_rollup
# sampled about every 10 ms by a poller on E-core 12 while the program runs
# on core 8. Three runs per variant; each line is the sample of largest Rss.
set -u
W=/zfs/worktrees/rig/tsrs-standing
P=/zfs/trig-pup/full/trig/misc/projects
. $W/cmds.sh
for proj in ts-pattern zod3; do
  cd $P/$proj
  for i in 1 2 3; do
    for v in main-pgo main-rel f7ed-rel a38f-rel tsrs; do
      taskset -c 8 $(cmd_of $v) > /dev/null 2>&1 &
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
