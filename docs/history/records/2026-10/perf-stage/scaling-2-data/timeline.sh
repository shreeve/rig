#!/bin/sh
# timeline.sh R [NAMES]: per-thread timelines, R runs of each named variant
# (all when NAMES is empty), ts-pattern then zod3, into $W/timeline$TAG:
#   trig4    Trig (773978d1d) at 4 checkers on E-cores 12-15
#   tsgo4    tsrs, Go order, 4 checkers, 12-15
#   tsdef4   tsrs, default mode, 4 checkers, 12-15
#   trig4on1 Trig at 4 checkers on core 12 alone: each checker's work with
#            no other core busy (the tasks run one after another)
#   tsgo4on1 tsrs, Go order, 4 checkers on core 12 alone
#   trig1    Trig at one checker on core 12
#   tsgo1    tsrs, Go order, one thread on core 12
#   tsgo1c   tsrs, Go order, one checker thread and one parse thread
#            (--checkers 1, not --singleThreaded) on core 12: its head
# Each recorded system-wide on the cores used: every context switch, the
# process's exec, write, writev and exit, and on Trig the probes of probes.sh
# (check_group's task with its k, each file's check, load, new_checker).
# perf script's text, gzipped, is what parse.py reads.
set -u
R=${1:-5}
. /zfs/worktrees/rig/scaling-2/cmds.sh
O=$W/timeline${TAG:-}; mkdir -p $O
ONLY=${2:-}
X773=$W/probe/trig773
EV="-e sched:sched_switch -e sched:sched_process_exec -e sched:sched_process_exit -e syscalls:sys_enter_write -e syscalls:sys_enter_writev -e syscalls:sys_enter_exit_group"
busy() {
  for _ in 1 2 3 4 5; do
    ps -eLo psr=,stat=,comm= | awk '$1 >= 12 && $1 <= 15 && $2 ~ /^R/ && $3 != "ps" && $3 != "awk" { f=1 } END { exit !f }' && return 0
    sleep 0.2
  done
  return 1
}
quiet() { while busy; do echo "# $(date +%T) waiting: a process runs on cores 12-15"; sleep 20; done; }
rec() { # rec NAME CORES PROBES CMD...
  name=$1 cores=$2 probes=$3; shift 3
  case " ${ONLY:-$name} " in *" $name "*) ;; *) return ;; esac
  f=$O/$name.$proj.$r
  sudo perf record -q -a -C $cores $EV $probes -o $f.data -- taskset -c $cores "$@" > $f.out 2>&1
  sudo perf script -i $f.data -F comm,pid,tid,cpu,time,event,trace 2>/dev/null | gzip > $f.txt.gz
  sudo rm -f $f.data
  cmp -s $f.out $O/ref.$proj && rm -f $f.out || echo "# $name $proj $r: output differs"
}
echo "# start $(date +%T) R=$R load $(cut -d' ' -f1-3 /proc/loadavg)"
for proj in ts-pattern zod3; do
  cd $P/$proj
  $(cmd_of t773 1) > $O/ref.$proj 2>&1
  r=1
  while [ $r -le $R ]; do
    quiet
    echo "# $proj round $r $(date +%T) load $(cut -d' ' -f1 /proc/loadavg)"
    rec trig4 12-15 "-e p773:*" $X773 -p tsconfig.trig.json --noEmit --checkers 4
    rec tsgo4 12-15 "" $(cmd_of tsgo 4)
    rec tsdef4 12-15 "" $(cmd_of tsdef 4)
    rec trig4on1 12 "-e p773:*" $X773 -p tsconfig.trig.json --noEmit --checkers 4
    rec tsgo4on1 12 "" $(cmd_of tsgo 4)
    rec trig1 12 "-e p773:*" $X773 -p tsconfig.trig.json --noEmit --singleThreaded
    rec tsgo1 12 "" $(cmd_of tsgo 1)
    rec tsgo1c 12 "" env RAYON_NUM_THREADS=1 $TSRS -p tsconfig.trig.json --noEmit --checkers 1 --checkerAssignment go --noLazyMembers
    r=$((r + 1))
  done
done
echo "# done $(date +%T) load $(cut -d' ' -f1-3 /proc/loadavg)"
