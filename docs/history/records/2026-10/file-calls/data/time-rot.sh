#!/bin/sh
# time-rot.sh N: standing-4's rotated timing (P-core 6, sibling 7 idle, perf stat,
# peak RSS), arms main-pgo and meta-pgo, Trig's six projects. Only after "pup: go".
set -u
N=${1:-20}
W=/zfs/worktrees/rig/trig-fileio
P=/zfs/trig-pup/full/trig/misc/projects
V="main meta"
O=$W/time; mkdir -p $O
EV=duration_time,user_time,system_time,cpu_core/cycles/u,cpu_core/cycles/k,cpu_core/instructions/u,page-faults
busy() {
  for _ in 1 2 3 4 5; do
    ps -eLo psr=,stat=,comm= | awk '($1 == 6 || $1 == 7) && $2 ~ /^R/ && $3 != "ps" && $3 != "awk" { f=1 } END { exit !f }' && return 0
    sleep 0.2
  done
  return 1
}
# Trig's cron suites start at 00, 04, 08, 12, 16 and 20:00: no round starts from
# HH:58 before one until 5 minutes after, or while one runs.
near_cron() {
  h=$(date +%-H); m=$(date +%-M)
  [ $((h % 4)) -eq 3 ] && [ $m -ge 58 ] && return 0
  [ $((h % 4)) -eq 0 ] && [ $m -lt 5 ] && return 0
  return 1
}
quiet() {
  while near_cron; do echo "# $(date +%T) waiting: Trig's cron suite is due"; sleep 30; done
  while pgrep -f 'tools/full-main' > /dev/null; do echo "# $(date +%T) waiting: Trig's full suite"; sleep 60; done
  while busy; do echo "# $(date +%T) waiting: core 6 or 7 busy"; sleep 20; done
}
run() {
  e=0
  /usr/bin/time -f "%M" -o $O/time taskset -c 12-19 perf stat -x, -e $EV -o $O/perf taskset -c 6 $W/packs/$2/bin -p tsconfig.trig.json --noEmit --singleThreaded > $O/out.$1.$2 2>&1 || e=$?
  f=$(awk -F, '/^[0-9]/ { k=$3; sub("cpu_core/", "", k); sub("/$", "", k); printf "%s=%s ", k, $1 }' $O/perf)
  echo "${f}rss_kb=$(tail -n 1 $O/time) exit=$e"
}
echo "# start $(date +%T) N=$N load $(cut -d' ' -f1-3 /proc/loadavg)"
for proj in zod3 ts-pattern tiny-invariant superstruct mitt neverthrow; do
  cd $P/$proj; quiet
  for v in $V; do run $proj $v > /dev/null; cp $O/out.$proj.$v $O/ref.$proj.$v; done
  cmp -s $O/ref.$proj.main $O/ref.$proj.meta && echo "# $proj: same output" || echo "# $proj: output DIFFERS"
  r=1
  while [ $r -le $N ]; do
    quiet
    set -- $V; k=$(( (r - 1) % $# )); while [ $k -gt 0 ]; do x=$1; shift; set -- "$@" $x; k=$((k - 1)); done
    for v in "$@"; do echo "$proj round=$r v=$v $(run $proj $v) load=$(cut -d' ' -f1 /proc/loadavg)"; done
    r=$((r + 1))
  done
done
echo "# done $(date +%T)"
