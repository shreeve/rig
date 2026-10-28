#!/bin/sh
# time.sh N: N rounds, every variant once a round, interleaved, ts-pattern
# then zod3, on P-core 1 with its sibling 2 idle. A round 0, not counted,
# records each project's reference output: Trig's from the 773978d1d build,
# tsrs's from the shipped one. One line per run: wall, user and system time,
# user and kernel cycles, user instructions, page faults, peak RSS, minor
# faults, exit, whether the output matches the reference, and the load.
set -u
N=${1:-20}
W=/zfs/worktrees/rig/tsrs-standing-2
P=$W/trig/misc/projects
. $W/cmds.sh
O=$W/time; mkdir -p $O
# Whether another thread is running on core 1 or 2, sampled 5 times.
busy() {
  for _ in 1 2 3 4 5; do
    ps -eLo psr=,stat=,comm= | awk '($1 == 1 || $1 == 2) && $2 ~ /^R/ && $3 != "ps" && $3 != "awk" { f=1 } END { exit !f }' && return 0
    sleep 0.2
  done
  return 1
}
quiet() {
  while pgrep -f 'tools/full-main' > /dev/null; do echo "# $(date +%T) waiting: Trig's full suite is running"; sleep 60; done
  while busy; do echo "# $(date +%T) waiting: a process runs on core 1 or 2"; sleep 20; done
}
run() { # run PROJ V -> fields
  e=0
  /usr/bin/time -f "%M %e %R" -o $O/time perf stat -x, -e duration_time,user_time,system_time,cpu_core/cycles/u,cpu_core/cycles/k,cpu_core/instructions/u,page-faults -o $O/perf taskset -c 1 $(cmd_of $2) > $O/out.$1.$2 2>&1 || e=$?
  f=$(awk -F, '/^[0-9]/ { k=$3; sub("cpu_core/", "", k); sub("/$", "", k); printf "%s=%s ", k, $1 }' $O/perf)
  set -- $(tail -n 1 $O/time)
  echo "${f}rss_kb=$1 minflt=$3 exit=$e"
}
echo "# start $(date +%T) N=$N load $(cut -d' ' -f1-3 /proc/loadavg)"
for proj in ts-pattern zod3; do
  cd $P/$proj
  quiet
  run $proj 773-pgo > /dev/null; cp $O/out.$proj.773-pgo $O/ref.$proj.trig
  run $proj tsrs > /dev/null; cp $O/out.$proj.tsrs $O/ref.$proj.tsrs
  cmp -s $O/ref.$proj.trig $O/ref.$proj.tsrs && echo "# $proj: Trig's output and tsrs's are the same" || echo "# $proj: Trig's output and tsrs's DIFFER"
  r=1
  while [ $r -le $N ]; do
    quiet
    for v in $V; do
      line=$(run $proj $v)
      case $v in tsrs*) ref=tsrs ;; *) ref=trig ;; esac
      same=1; cmp -s $O/ref.$proj.$ref $O/out.$proj.$v || { same=0; cp $O/out.$proj.$v $O/diff.$proj.$r.$v; }
      echo "$proj round=$r v=$v $line same=$same load=$(cut -d' ' -f1 /proc/loadavg)"
    done
    r=$((r + 1))
  done
done
echo "# done $(date +%T) load $(cut -d' ' -f1-3 /proc/loadavg)"
