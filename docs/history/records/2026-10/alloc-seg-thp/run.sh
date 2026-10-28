#!/bin/sh
# run.sh: Trig under perf and without it at one checker (core 6, 7 idle),
# 20 rounds, then at four checkers (cores 0,5,6,7), then huge pages
# (huge.py, and the tsrs-standing record's way: huge-ts.sh), and its
# sys.sh (sys-ts.sh).
A=/zfs/worktrees/rig/alloc-seg-thp
cd $A
V="main=$A/trig-main/bin seg=$A/trig-seg/bin segnp=$A/trig-segnp/bin seglead=$A/trig-seglead/bin tbl=$A/trig-tbl/bin"
python3 measure.py 20 $V > trig-perf.md 2> trig-perf.err
NOPERF=1 python3 measure.py 20 $V > trig-wall.md 2> trig-wall.err
FOUR=1 python3 measure.py 10 $V > trig-perf4.md 2> trig-perf4.err
python3 huge.py 3 $V > huge.md 2> huge.err
sh huge-ts.sh > huge-ts.txt 2>&1
sh sys-ts.sh > sys-ts.txt 2>&1
echo done
