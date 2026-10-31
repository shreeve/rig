#!/bin/sh
# time.sh N [PROJECTS]: N rounds, every variant once a round, interleaved and
# rotated,
# each project in turn (ts-pattern and zod3 unless named), on P-core 6 with
# its sibling 7 idle. A round 0, not counted,
# records each variant's reference output and says whether it is the same
# bytes as tsrs's. One line per run: wall, user and system time, user and
# kernel cycles, user instructions, page faults, dTLB walks (load, store),
# loads that missed the dTLB and hit the STLB, iTLB walks, peak RSS, minor
# faults, exit, whether the output matches the variant's reference, the
# load, and Linux's free 2 MiB blocks before the run (/proc/buddyinfo, DMA
# left out, as Rig's huge-page gate counts them: it asks for huge pages
# only above 128).
set -u
N=${1:-20}
PROJS=${2:-ts-pattern zod3}
W=/zfs/worktrees/rig/codegen-gap
P=$W/trig/misc/projects
. $W/cmds.sh
O=$W/time; mkdir -p $O
EV=duration_time,user_time,system_time,cpu_core/cycles/u,cpu_core/cycles/k,cpu_core/instructions/u,page-faults,cpu_core/dtlb_load_misses.walk_completed/,cpu_core/dtlb_store_misses.walk_completed/,cpu_core/dtlb_load_misses.stlb_hit/,cpu_core/itlb_misses.walk_completed/
# Whether another thread is running on core 6 or 7, sampled 5 times.
busy() {
  for _ in 1 2 3 4 5; do
    ps -eLo psr=,stat=,comm= | awk '($1 == 6 || $1 == 7) && $2 ~ /^R/ && $3 != "ps" && $3 != "awk" { f=1 } END { exit !f }' && return 0
    sleep 0.2
  done
  return 1
}
quiet() {
  while pgrep -f 'tools/full-main' > /dev/null; do echo "# $(date +%T) waiting: Trig's full suite is running"; sleep 60; done
  while busy; do echo "# $(date +%T) waiting: a process runs on core 6 or 7"; sleep 20; done
}
huge2m() { awk '$4 != "DMA" { n += $14 + 2 * $15 } END { print n }' /proc/buddyinfo; }
run() { # run PROJ V -> fields
  e=0; h=$(huge2m)
  /usr/bin/time -f "%M %e %R" -o $O/time taskset -c 12-19 perf stat -x, -e $EV -o $O/perf taskset -c 6 $(cmd_of $2) > $O/out.$1.$2 2>&1 || e=$?
  f=$(awk -F, '/^[0-9]/ { k=$3; sub("cpu_core/", "", k); sub("/$", "", k); printf "%s=%s ", k, $1 }' $O/perf)
  set -- $(tail -n 1 $O/time)
  echo "${f}rss_kb=$1 minflt=$3 exit=$e huge2m=$h"
}
echo "# start $(date +%T) N=$N load $(cut -d' ' -f1-3 /proc/loadavg)"
for proj in $PROJS; do
  cd $P/$proj
  quiet
  for v in $V; do run $proj $v > /dev/null; cp $O/out.$proj.$v $O/ref.$proj.$v; done
  for v in $V; do
    cmp -s $O/ref.$proj.$v $O/ref.$proj.tsrs && echo "# $proj: $v's output and tsrs's are the same" || echo "# $proj: $v's output and tsrs's DIFFER"
  done
  r=1
  while [ $r -le $N ]; do
    quiet
    # The variants in turn, each round starting one later, so that the first
    # run after the wait, on a core that idled, falls to each in turn.
    set -- $V; k=$(( (r - 1) % $# )); while [ $k -gt 0 ]; do x=$1; shift; set -- "$@" $x; k=$((k - 1)); done
    for v in "$@"; do
      line=$(run $proj $v)
      same=1; cmp -s $O/ref.$proj.$v $O/out.$proj.$v || { same=0; cp $O/out.$proj.$v $O/diff.$proj.$r.$v; }
      echo "$proj round=$r v=$v $line same=$same load=$(cut -d' ' -f1 /proc/loadavg)"
    done
    r=$((r + 1))
  done
done
echo "# done $(date +%T) load $(cut -d' ' -f1-3 /proc/loadavg)"
