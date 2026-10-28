#!/bin/sh
# On pup, core 3: every page fault trap, with its address, of the traced
# build (charged to owners by memtrace.py) and of tsrs (by mapping); and
# kernel cycles with user call chains (frame pointers) on fp.
set -u
. /zfs/worktrees/rig/memory-traffic/cmds.sh
p=$1
O=$W/faults; mkdir -p $O
cd $P/$p
quiet8
RIG_ALLOC_TRACE_FILE=$O/$p.trace.bin perf record -q -k CLOCK_MONOTONIC -d -e page-faults -c 1 -o $O/$p.trace.data taskset -c 3 $(cmd_of trace) > /dev/null 2>&1
perf script -i $O/$p.trace.data -F time,event,addr,ip --ns 2>/dev/null > $O/$p.trace.samples
quiet8
perf record -q -k CLOCK_MONOTONIC -d -e page-faults -c 1 -o $O/$p.tsrs.data taskset -c 3 $(cmd_of tsrs) > /dev/null 2>&1
perf script -i $O/$p.tsrs.data -F time,event,addr,ip --ns 2>/dev/null > $O/$p.tsrs.samples
quiet8
perf record -q -e cpu_core/cycles/k -c 100003 -g -o $O/$p.fp.kern.data taskset -c 3 $(cmd_of fp) > /dev/null 2>&1
perf report -i $O/$p.fp.kern.data --no-children --sort sym --stdio 2>/dev/null | head -80 > $O/$p.fp.kern.syms
perf report -i $O/$p.fp.kern.data --children --sort sym --stdio -g none 2>/dev/null | head -150 > $O/$p.fp.kern.children
echo done
