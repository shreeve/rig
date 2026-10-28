#!/bin/sh
# mm.sh R: R runs each of Trig 773978d1d and 2c01f07dd at 4 checkers on
# E-cores 12-15, recorded system-wide on those cores: every mmap, munmap,
# mremap and madvise call (with its user call stack), TLB flush, and
# function-call IPI, with the phase probes. Then Trig 773978d1d with
# RIG_SCHED_STATS=1. perf script's text, gzipped, is what mm.py reads.
set -u
R=${1:-3}
. /zfs/worktrees/rig/scaling-2/cmds.sh
O=$W/mm; mkdir -p $O
EV="-e sched:sched_process_exec -e sched:sched_process_exit -e syscalls:sys_enter_writev -e syscalls:sys_enter_exit_group -e syscalls:sys_enter_munmap -e syscalls:sys_enter_madvise -e syscalls:sys_enter_mmap -e syscalls:sys_enter_mremap -e tlb:tlb_flush -e irq_vectors:call_function_entry -e irq_vectors:call_function_single_entry"
for proj in ts-pattern zod3; do
  cd $P/$proj
  r=1
  while [ $r -le $R ]; do
    for b in 773 2c0; do
      f=$O/t$b.$proj.$r
      sudo perf record -q -a -C 12-15 -g $EV -e "p$b:*" -o $f.data -- taskset -c 12-15 $W/probe/trig$b -p tsconfig.trig.json --noEmit --checkers 4 > /dev/null 2>&1
      sudo perf script --no-inline -i $f.data -F comm,pid,tid,cpu,time,event,trace,ip,sym 2>/dev/null | gzip > $f.txt.gz
      sudo rm -f $f.data
    done
    r=$((r + 1))
  done
  RIG_SCHED_STATS=1 taskset -c 12-15 $(cmd_of t773 4) 2>&1 >/dev/null | grep -v "error TS" > $O/sched-stats.$proj.txt
done
