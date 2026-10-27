#!/bin/sh
# run.sh: bench/hash builds (cores 0,5), then Trig and bench/hash timed on core 6.
set -u
A=/zfs/worktrees/rig/alloc-peak
export PATH=$HOME/.local/bin:$PATH XDG_CACHE_HOME=/zfs/rig/xdg-cache
cd $A
sh build.sh main final || { echo 'build failed'; exit 1; }
for n in main final; do
  RIG=$A/rig-$n/bin/rig taskset -c 0,5 python3 $A/rig-final/bench/hash/bench-hash --out $A/hb-$n --build-only --variants rig-fast > hb-build-$n.log 2>&1 || { echo "hb build $n failed"; exit 1; }
done
echo 'hb built'
python3 measure.py 20 main=$A/trig-main/bin final=$A/trig-final/bin > trig-perf.md 2> trig-perf.err || { echo 'perf failed'; exit 1; }
echo 'perf finished'
NOPERF=1 python3 measure.py 20 main=$A/trig-main/bin final=$A/trig-final/bin > trig-wall.md 2> trig-wall.err || { echo 'nopf failed'; exit 1; }
echo 'nopf finished'
PIN='taskset -c 6' python3 hbab.py 9 main=$A/hb-main/rig-fast final=$A/hb-final/rig-fast > hb-pup.txt 2> hb-pup.err || { echo 'hb failed'; exit 1; }
echo 'ALL FINISHED'
