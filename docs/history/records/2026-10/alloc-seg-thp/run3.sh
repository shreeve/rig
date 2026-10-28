#!/bin/sh
# run3.sh: run2's Trig timing again, with Trig built by main before the
# rebase (36422da59, "old") beside main (099c1bff3) and seglead, to tell
# the machine's state from the Rig's: 20 rounds at one checker under perf
# and without it, 10 at four. Results in *-3.md.
A=/zfs/worktrees/rig/alloc-seg-thp
cd $A
n=0; q=0
while [ $n -lt 180 ] && [ $q -lt 2 ]; do
  if ! pgrep -x tsc > /dev/null && awk '{ exit !($1 < 2.5) }' /proc/loadavg; then q=$((q + 1)); else q=0; fi
  sleep 60; n=$((n + 1))
done
echo "quiet after $n min: $(cat /proc/loadavg)"
V="old=$A/trig-old/bin main=$A/trig-main/bin seglead=$A/trig-seglead/bin"
python3 measure.py 20 $V > trig-perf-3.md 2> trig-perf-3.err
NOPERF=1 python3 measure.py 20 $V > trig-wall-3.md 2> trig-wall-3.err
FOUR=1 python3 measure.py 10 $V > trig-perf4-3.md 2> trig-perf4-3.err
echo done
