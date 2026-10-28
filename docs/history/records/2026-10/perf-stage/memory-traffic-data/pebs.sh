#!/bin/sh
# On pup, core 3: precise memory samples with data addresses.
#   pebs.sh trace PROJECT RUN: the traced build, its trace beside the samples
#   pebs.sh rel|tsrs PROJECT RUN: by sampled instruction and mapping only
# Events: L1, L2 and L3 load misses, loads that missed the STLB, and loads
# blocked by store forwarding, each at its own period.
set -u
. /zfs/worktrees/rig/memory-traffic/cmds.sh
v=$1 p=$2 r=$3
O=$W/pebs; mkdir -p $O
cd $P/$p
EV="-e cpu_core/mem_load_retired.l1_miss,period=4001/upp -e cpu_core/mem_load_retired.l2_miss,period=307/upp -e cpu_core/mem_load_retired.l3_miss,period=97/upp -e cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp -e cpu_core/ld_blocks.store_forward,period=1301/upp"
quiet8
if [ $v = trace ]; then
  RIG_ALLOC_TRACE_FILE=$O/$p.trace.$r.bin perf record -q -k CLOCK_MONOTONIC -d $EV -o $O/$p.$v.$r.data taskset -c 3 $(cmd_of $v) > /dev/null 2> $O/$p.$v.$r.err
else
  perf record -q -k CLOCK_MONOTONIC -d $EV -o $O/$p.$v.$r.data taskset -c 3 $(cmd_of $v) > /dev/null 2> $O/$p.$v.$r.err
fi
perf script -i $O/$p.$v.$r.data -F time,event,addr,ip --ns 2>/dev/null > $O/$p.$v.$r.samples
# The load address of a position-independent binary: its mapping at offset 0.
b=$(cmd_of $v | tr ' ' '\n' | grep -m1 '^/')
if readelf -h $b | grep -q DYN; then
  perf script -i $O/$p.$v.$r.data --show-mmap-events 2>/dev/null | grep -m1 "MMAP.*@ 0 .*$b\$" | sed 's/.*\[\(0x[0-9a-f]*\)(.*/\1/' > $O/$p.$v.$r.bias
else echo 0 > $O/$p.$v.$r.bias; fi
perf report -i $O/$p.$v.$r.data --stats 2>/dev/null | grep -iE "lost|throttle|SAMPLE" > $O/$p.$v.$r.stats
wc -l < $O/$p.$v.$r.samples
