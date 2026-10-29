#!/bin/sh
# time.sh N: N rounds; in each, for 1, 2, 4 and 8 checkers, every variant
# once, interleaved, ts-pattern then zod3, pinned to E-cores (cores_of).
# One line per run: perf stat's wall, user and system time, task-clock,
# E-core user and kernel cycles and user instructions, page faults,
# context switches and migrations; peak RSS; whether the output matches
# the reference (Trig's one-checker output; every variant prints the same
# bytes on these projects); and the load.
set -u
N=${1:-10}
. /zfs/worktrees/rig/scaling-2/cmds.sh
O=$W/time; mkdir -p $O
busy() { # another thread running on cores 12-19, sampled 5 times
  for _ in 1 2 3 4 5; do
    ps -eLo psr=,stat=,comm= | awk '$1 >= 12 && $1 <= 19 && $2 ~ /^R/ && $3 != "ps" && $3 != "awk" { f=1 } END { exit !f }' && return 0
    sleep 0.2
  done
  return 1
}
quiet() {
  while pgrep -f 'tools/full-main' > /dev/null; do echo "# $(date +%T) waiting: Trig's full suite"; sleep 60; done
  while busy; do echo "# $(date +%T) waiting: a process runs on cores 12-19"; sleep 20; done
}
run() { # run PROJ V N
  e=0
  /usr/bin/time -f "%M" -o $O/time perf stat -x, -e duration_time,user_time,system_time,task-clock,cpu_atom/cycles/u,cpu_atom/cycles/k,cpu_atom/instructions/u,page-faults,context-switches,cpu-migrations -o $O/perf taskset -c $(cores_of $3) $(cmd_of $2 $3) > $O/out 2>&1 || e=$?
  f=$(awk -F, '/^[0-9]/ { k=$3; sub("cpu_atom/", "", k); sub("/$", "", k); gsub("/", "", k); printf "%s=%s ", k, $1 }' $O/perf)
  same=1; cmp -s $O/ref.$1 $O/out || { same=0; cp $O/out $O/diff.$1.$2.$3; }
  echo "$1 v=$2 n=$3 ${f}rss_kb=$(tail -n 1 $O/time) exit=$e same=$same load=$(cut -d' ' -f1 /proc/loadavg)"
}
echo "# start $(date +%T) N=$N load $(cut -d' ' -f1-3 /proc/loadavg)"
for proj in ts-pattern zod3; do
  cd $P/$proj
  $(cmd_of t773 1) > $O/ref.$proj 2>&1
  r=1
  while [ $r -le $N ]; do
    quiet
    for n in 1 2 4 8; do
      vs="t773 tsgo tsdef"; case $n in 1|4) vs="t773 t2c0 tsgo tsdef" ;; esac
      for v in $vs; do echo "$(run $proj $v $n) round=$r"; done
    done
    r=$((r + 1))
  done
done
echo "# done $(date +%T) load $(cut -d' ' -f1-3 /proc/loadavg)"
