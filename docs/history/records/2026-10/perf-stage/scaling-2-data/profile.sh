#!/bin/sh
# profile.sh R: R sampled profiles each (a sample every 4M E-core cycles, about
# 1.3 ms, as pup caps samples at 1000 a second per core; frame
# pointer call stacks) on E-cores 12-15, with the process's exec, writev
# and exit and Trig's probes as phase marks:
#   trig4  Trig 773978d1d at 4 checkers;  trig1  Trig at one checker (core 12)
#   tsgo4  tsrs Go order at 4 checkers (stripped: kernel and user only)
# perf script's text, gzipped, is what profile.py reads.
set -u
R=${1:-8}
. /zfs/worktrees/rig/scaling-2/cmds.sh
O=$W/profile; mkdir -p $O
X773=$W/probe/trig773
EV="-e sched:sched_process_exec -e sched:sched_process_exit -e syscalls:sys_enter_writev -e syscalls:sys_enter_write -e syscalls:sys_enter_exit_group"
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
  f=$O/$name.$proj.$r
  sudo perf record -q -c 4000000 -g -e cpu_atom/cycles/ $EV $probes -o $f.data -- taskset -c $cores "$@" > /dev/null 2>&1
  sudo perf script --no-inline -i $f.data -F comm,pid,tid,time,event,trace,ip,sym 2>/dev/null | gzip > $f.txt.gz
  sudo rm -f $f.data
}
echo "# start $(date +%T) R=$R load $(cut -d' ' -f1-3 /proc/loadavg)"
for proj in ts-pattern zod3; do
  cd $P/$proj
  r=1
  while [ $r -le $R ]; do
    quiet
    rec trig4 12-15 "-e p773:*" $X773 -p tsconfig.trig.json --noEmit --checkers 4
    rec trig1 12 "-e p773:*" $X773 -p tsconfig.trig.json --noEmit --singleThreaded
    rec tsgo4 12-15 "" $(cmd_of tsgo 4)
    r=$((r + 1))
  done
done
echo "# done $(date +%T) load $(cut -d' ' -f1-3 /proc/loadavg)"
