#!/bin/sh
# spillrun.sh BUILD RUNS: perf record instructions (every 10M) over RUNS runs of ts-pattern at one checker on core 8, then spills.py.
W=/zfs/worktrees/rig/map-stage
b=$1; n=${2:-30}
cd $W/trig/misc/projects/ts-pattern
cat > /tmp/sp-loop-$b.sh <<LOOP
for i in \$(seq $n); do $W/packs/$b/bin -p tsconfig.trig.json --noEmit --singleThreaded; done
LOOP
taskset -c 8 perf record -q -e cpu_core/instructions/u -c 10000019 -o /tmp/sp-$b.data -- sh /tmp/sp-loop-$b.sh > /dev/null 2>&1
echo "== $b"
python3 $W/spills.py $W/packs/$b/bin /tmp/sp-$b.data $n ${INSTR:?instructions per run}
