#!/bin/sh
# run.sh: every pup measurement, one after another: bench/hash's builds
# (cores 0,1), Trig under perf and without it (measure.py), bench/hash
# twice on core 8 (hbsum.py), then the runtime benches (bench.sh).
A=/zfs/worktrees/rig/alloc-thp16
export PATH=$HOME/.local/bin:$PATH XDG_CACHE_HOME=/zfs/rig/xdg-cache
V=zig-foa:rigmain,zig-foa:rigmain2,zig-foa:rigthp16
cd $A/hb/bench/hash
taskset -c 0,1 python3 bench-hash --variants $V --out $A/hb-out --build-only > $A/hb-build.log 2>&1 || { echo "hb build failed"; exit 1; }
cd $A
python3 measure.py 20 main=$A/trig-main/bin thp16=$A/trig-thp16/bin > trig-perf.md 2> trig-perf.err
NOPERF=1 python3 measure.py 20 main=$A/trig-main/bin thp16=$A/trig-thp16/bin > trig-wall.md 2> trig-wall.err
cd $A/hb/bench/hash
for r in 1 2; do taskset -c 8 python3 bench-hash --variants $V --out $A/hb-out --time-only --reps 9 --mem > $A/hb-pup-$r.txt 2>&1; done
cd $A
sh bench.sh build main thp16 > benches-build.log 2>&1
sh bench.sh time 5 main thp16 > benches-pup.log 2>&1
echo done
