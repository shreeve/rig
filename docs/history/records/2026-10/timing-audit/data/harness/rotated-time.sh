#!/bin/sh
# pgo-broad: Trig 806e0a1 by Rig 928b44bf2, three builds: today's PGO
# (standing-6's, trained on mitt, neverthrow, superstruct and zod3), PGO
# trained on every TypeScript compiler and conformance case (a), and that
# with BOLT by the same workload (b); plus a byte-identical copy of
# today's as the A/A arm (c). One checker and four, rotated each round.
# One checker on P-core 6 (sibling 7 idle); four on P-cores 0,6,8,10
# (siblings 5,7,9,11 idle). Binaries run from tmpfs (/tmp/pgo-broad).
# Lines and fields as standing-5's time.sh.
set -u
N=${1:-20}
PROJS=${2:-mitt neverthrow zod3 ts-pattern superstruct tiny-invariant}
W=/zfs/worktrees/rig/pgo-broad/time-run
P=/zfs/trig-pup/full/trig/misc/projects
V="s1 c1 a1 b1 s4 c4 a4 b4"
cmd_of() {
  t="-p tsconfig.trig.json --noEmit"
  case $1 in
    s1) echo "taskset -c 6 /tmp/pgo-broad/s6 $t --singleThreaded" ;;
    c1) echo "taskset -c 6 /tmp/pgo-broad/s6copy $t --singleThreaded" ;;
    a1) echo "taskset -c 6 /tmp/pgo-broad/a $t --singleThreaded" ;;
    b1) echo "taskset -c 6 /tmp/pgo-broad/b $t --singleThreaded" ;;
    s4) echo "taskset -c 0,6,8,10 /tmp/pgo-broad/s6 $t --checkers 4" ;;
    c4) echo "taskset -c 0,6,8,10 /tmp/pgo-broad/s6copy $t --checkers 4" ;;
    a4) echo "taskset -c 0,6,8,10 /tmp/pgo-broad/a $t --checkers 4" ;;
    b4) echo "taskset -c 0,6,8,10 /tmp/pgo-broad/b $t --checkers 4" ;;
  esac
}
O=$W/time; mkdir -p $O
EV=duration_time,user_time,system_time,cpu_core/cycles/u,cpu_core/cycles/k,cpu_core/instructions/u,page-faults
# Whether another thread runs on the timing cores or their siblings.
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
run() { # run PROJ V -> fields
  e=0
  /usr/bin/time -f "%M %e %R" -o $O/time taskset -c 12-19 perf stat -x, -e $EV -o $O/perf $(cmd_of $2) > $O/out.$1.$2 2>&1 || e=$?
  f=$(awk -F, '/^[0-9]/ { k=$3; sub("cpu_core/", "", k); sub("/$", "", k); printf "%s=%s ", k, $1 }' $O/perf)
  set -- $(tail -n 1 $O/time)
  echo "${f}rss_kb=$1 minflt=$3 exit=$e"
}
echo "# start $(date +%T) N=$N load $(cut -d' ' -f1-3 /proc/loadavg)"
for proj in $PROJS; do
  cd $P/$proj
  quiet
  for v in $V; do run $proj $v > /dev/null; cp $O/out.$proj.$v $O/ref.$proj.$v; done
  for v in $V; do
    cmp -s $O/ref.$proj.$v $O/ref.$proj.s1 && echo "# $proj: $v's output and s1's are the same" || echo "# $proj: $v's output and s1's DIFFER"
  done
  r=1
  while [ $r -le $N ]; do
    quiet
    # Each round starts one variant later, so the first run after the wait,
    # on a core that idled, falls to each in turn.
    set -- $V; k=$(( (r - 1) % $# )); while [ $k -gt 0 ]; do x=$1; shift; set -- "$@" $x; k=$((k - 1)); done
    for v in "$@"; do
      line=$(run $proj $v)
      same=1; cmp -s $O/ref.$proj.$v $O/out.$proj.$v || same=0
      echo "$proj round=$r v=$v $line same=$same load=$(cut -d' ' -f1 /proc/loadavg)"
    done
    r=$((r + 1))
  done
done
echo "# done $(date +%T)"
date +%H:%M:%S > $W/done
