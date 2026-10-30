#!/bin/sh
# walks.sh N: N interleaved runs of Rig main's Trig and shipped tsrs on each
# project, on P-core 1 with its sibling idle, counting the cycles a page
# walk was active (loads, stores, code) beside user cycles, so the walks'
# share of the user cycles is known; with free 2 MiB blocks before each run.
set -u
N=${1:-5}
W=/zfs/worktrees/rig/tsrs-standing-3
P=$W/trig/misc/projects
. $W/cmds.sh
EV=cpu_core/cycles/u,cpu_core/dtlb_load_misses.walk_active/u,cpu_core/dtlb_store_misses.walk_active/u,cpu_core/itlb_misses.walk_active/u,cpu_core/dtlb_load_misses.walk_completed/u,cpu_core/dtlb_load_misses.stlb_hit/u,page-faults
busy() {
  for _ in 1 2 3 4 5; do
    ps -eLo psr=,stat=,comm= | awk '($1 == 1 || $1 == 2) && $2 ~ /^R/ && $3 != "ps" && $3 != "awk" { f=1 } END { exit !f }' && return 0
    sleep 0.2
  done
  return 1
}
quiet() { while busy; do echo "# $(date +%T) waiting: a process runs on core 1 or 2"; sleep 20; done; }
huge2m() { awk '$4 != "DMA" { n += $14 + 2 * $15 } END { print n }' /proc/buddyinfo; }
for proj in ts-pattern zod3; do
  cd $P/$proj
  r=1
  while [ $r -le $N ]; do
    quiet
    for v in 1b2-pgo tsrs; do
      h=$(huge2m)
      perf stat -x, -e $EV -o $W/walks.perf taskset -c 1 $(cmd_of $v) > /dev/null 2>&1
      f=$(awk -F, '/^[0-9]/ { k=$3; sub("cpu_core/", "", k); sub("/u$", "", k); sub("/$", "", k); printf "%s=%s ", k, $1 }' $W/walks.perf)
      echo "$proj round=$r v=$v ${f}huge2m=$h"
    done
    r=$((r + 1))
  done
done
