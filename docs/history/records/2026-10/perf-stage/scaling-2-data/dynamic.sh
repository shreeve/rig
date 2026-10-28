#!/bin/sh
# dynamic.sh R: R interleaved rounds at 4 checkers on E-cores 12-15:
# Trig 773978d1d in Go's assignment and with TRIG_CHECKERS=dynamic (files
# from one queue, heaviest first: not tsc's output in general), and tsrs
# in Go order and its default mode. Wall by perf stat; whether the output
# is Go mode's.
set -u
R=${1:-5}
. /zfs/worktrees/rig/scaling-2/cmds.sh
O=$W/dynamic; mkdir -p $O
busy() {
  for _ in 1 2 3 4 5; do
    ps -eLo psr=,stat=,comm= | awk '$1 >= 12 && $1 <= 15 && $2 ~ /^R/ && $3 != "ps" && $3 != "awk" { f=1 } END { exit !f }' && return 0
    sleep 0.2
  done
  return 1
}
quiet() {
  while pgrep -f 'tools/full-main' > /dev/null; do echo "# $(date +%T) waiting: Trig's full suite"; sleep 60; done
  while busy; do echo "# $(date +%T) waiting: a process runs on cores 12-15"; sleep 20; done
}
for proj in ts-pattern zod3; do
  cd $P/$proj
  $(cmd_of t773 4) > $O/ref.$proj 2>&1
  r=1
  while [ $r -le $R ]; do
    quiet
    for v in t773 t773dyn tsgo tsdef; do
      case $v in t773dyn) e="env TRIG_CHECKERS=dynamic"; c=$(cmd_of t773 4) ;; *) e=""; c=$(cmd_of $v 4) ;; esac
      perf stat -x, -e duration_time,task-clock -o $O/st -- taskset -c 12-15 $e $c > $O/out 2>&1
      cmp -s $O/out $O/ref.$proj && same=1 || same=0
      echo "$proj v=$v $(awk -F, '/^[0-9]/ { printf "%s=%s ", $3, $1 }' $O/st)same=$same round=$r load=$(cut -d' ' -f1 /proc/loadavg)"
    done
    r=$((r + 1))
  done
done
