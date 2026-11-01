#!/bin/sh
# time-ab.sh CONFIG [N] [PROJECTS]: time Trig's projects under several arms
# on pup, with no arm favoured by its place in a round.
#
# CONFIG is a shell file that sets V (the arm names, space-separated) and
# defines cmd_of ARM, which prints the arm's command (with its taskset);
# W (where results go) and, optionally, WARM (one command per core group,
# separated by ";", run and discarded before each round). Each round:
# wait for quiet cores and for no Trig suite; run the warm-up commands;
# then run every arm once, in an order shuffled by the round's number
# (seeded, so a rerun repeats it), so each arm follows each other arm and
# the warm-up about equally often. A fixed or rotated order lets the arm
# after the round's start, or after a four-core run, pay a cold-core cost
# (1-2 ms on a 25 ms project) that no other arm pays.
#
# Output: lines "PROJECT round=R v=ARM <perf fields> rss_kb= minflt= exit=
# same= load=", as standing-5's time.sh, and "# PROJECT: ARM's output and
# FIRST's are the same|DIFFER". Binaries should run from tmpfs (/tmp) so
# their text pages count the same in peak RSS.
set -u
CONFIG=$(readlink -f "$1")
N=${2:-20}
PROJS=${3:-mitt neverthrow zod3 ts-pattern superstruct tiny-invariant}
P=/zfs/trig-pup/full/trig/misc/projects
WARM=""
. "$CONFIG"
O=$W/time; mkdir -p $O
EV=duration_time,user_time,system_time,cpu_core/cycles/u,cpu_core/cycles/k,cpu_core/instructions/u,page-faults
# Whether another thread runs on the timing cores (0, 5-11) or their siblings.
busy() {
  for _ in 1 2 3 4 5; do
    ps -eLo psr=,stat=,comm= | awk '($1==0||$1==5||$1==6||$1==7||$1==8||$1==9||$1==10||$1==11) && $2 ~ /^R/ && $3 != "ps" && $3 != "awk" { f=1 } END { exit !f }' && return 0
    sleep 0.2
  done
  return 1
}
quiet() {
  while pgrep -f "tools/full-main" > /dev/null; do echo "# $(date +%T) waiting: Trig's full suite"; sleep 60; done
  while busy; do echo "# $(date +%T) waiting: a process runs on the timing cores"; sleep 20; done
}
# Run PROJ's arm V once, under perf stat, and print its fields. An arm's
# command starts `taskset -c CORES`: perf runs pinned to the same cores,
# so the counted program starts where it runs, and with --no-scale. A
# cpu_core event cannot run while the program is on an E-core; started
# there (perf on 12-19, the program pinned only once taskset ran), perf
# scaled its counts by enabled over running time, a swing of 7-10M
# instructions a run (row 49).
run() { # run PROJ V -> fields
  e=0
  set -- $1 $2 $(cmd_of $2)
  proj=$1 arm=$2; shift 2
  [ "$1" = taskset ] && [ "$2" = -c ] || { echo "# $arm: command must start with taskset -c CORES" >&2; exit 2; }
  cores=$3; shift 3
  /usr/bin/time -f "%M %e %R" -o $O/time taskset -c $cores perf stat --no-scale -x, -e $EV -o $O/perf "$@" > $O/out.$proj.$arm 2>&1 || e=$?
  f=$(awk -F, '/^[0-9]/ { k=$3; sub("cpu_core/", "", k); sub("/$", "", k); printf "%s=%s ", k, $1 }' $O/perf)
  set -- $(tail -n 1 $O/time)
  echo "${f}rss_kb=$1 minflt=$3 exit=$e"
}
warm() {
  [ -n "$WARM" ] || return 0
  echo "$WARM" | tr ';' '\n' | while read -r c; do [ -n "$c" ] && sh -c "$c" > /dev/null 2>&1; done
}
# The arms in round R's order: a shuffle seeded by R.
order() {
  echo $V | tr ' ' '\n' | awk -v seed=$1 'BEGIN { srand(seed) } { print rand(), $0 }' | sort -n | cut -d' ' -f2 | tr '\n' ' '
}
FIRST=${V%% *}
echo "# start $(date +%T) N=$N load $(cut -d' ' -f1-3 /proc/loadavg)"
for proj in $PROJS; do
  cd $P/$proj
  quiet
  for v in $V; do run $proj $v > /dev/null; cp $O/out.$proj.$v $O/ref.$proj.$v; done
  for v in $V; do
    cmp -s $O/ref.$proj.$v $O/ref.$proj.$FIRST && echo "# $proj: $v's output and $FIRST's are the same" || echo "# $proj: $v's output and $FIRST's DIFFER"
  done
  r=1
  while [ $r -le $N ]; do
    quiet
    warm
    for v in $(order $r); do
      line=$(run $proj $v)
      same=1; cmp -s $O/ref.$proj.$v $O/out.$proj.$v || same=0
      echo "$proj round=$r v=$v $line same=$same load=$(cut -d' ' -f1 /proc/loadavg)"
    done
    r=$((r + 1))
  done
done
echo "# done $(date +%T)"
date +%H:%M:%S > $W/done
