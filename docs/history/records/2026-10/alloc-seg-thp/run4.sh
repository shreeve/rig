#!/bin/sh
# run4.sh: the quiet-window re-measure (2026-10-27, 21:2x), main
# 099c1bff3 against seglead (5ce75a2d9): one checker 20 rounds on core 6,
# four checkers 10 rounds on cores 0,5,6,7, under perf; AnonHugePages by
# huge.py; the load before and after. Results in *-4.md.
A=/zfs/worktrees/rig/alloc-seg-thp
cd $A
echo "before: $(cat /proc/loadavg)"
ps -eo psr,pcpu,user,args --sort=-pcpu | head -6 | cut -c1-100
V="main=$A/trig-main/bin seglead=$A/trig-seglead/bin"
python3 measure.py 20 $V > trig-perf-4.md 2> trig-perf-4.err
echo "after one checker: $(cat /proc/loadavg)"
FOUR=1 python3 measure.py 10 $V > trig-perf4-4.md 2> trig-perf4-4.err
python3 huge.py 3 $V > huge-4.md 2> huge-4.err
echo "after: $(cat /proc/loadavg)"
echo done
