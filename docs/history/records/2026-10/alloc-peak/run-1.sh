#!/bin/sh
# run.sh: bench/hash builds (cores 0,5), then Trig and bench/hash timed on core 6.
set -u
A=/zfs/worktrees/rig/alloc-peak
export PATH=$HOME/.local/bin:$PATH XDG_CACHE_HOME=/zfs/rig/xdg-cache
cd $A
for n in pre main fix peakfree; do
  RIG=$A/rig-$n/bin/rig taskset -c 0,5 python3 $A/rig-fix/bench/hash/bench-hash --out $A/hb-$n --build-only --variants rig-fast > hb-build-$n.log 2>&1 || { echo "hb build $n failed"; exit 1; }
done
echo "hb built"
python3 measure.py 20 main=$A/trig-main/bin fix=$A/trig-fix/bin peakfree=$A/trig-peakfree/bin > trig-perf.md 2> trig-perf.err || { echo "perf failed"; exit 1; }
echo "perf done"
NOPERF=1 python3 measure.py 20 main=$A/trig-main/bin fix=$A/trig-fix/bin peakfree=$A/trig-peakfree/bin > trig-wall.md 2> trig-wall.err || { echo "wall failed"; exit 1; }
echo "wall done"
PIN="taskset -c 6" python3 hbab.py 9 pre=$A/hb-pre/rig-fast main=$A/hb-main/rig-fast fix=$A/hb-fix/rig-fast peakfree=$A/hb-peakfree/rig-fast > hb-pup.txt 2> hb-pup.err || { echo "hb failed"; exit 1; }
echo "all done"
