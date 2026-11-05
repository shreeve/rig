#!/bin/sh
# prof.sh ARM WHERE PROJECT RUNS: one LBR cycles:u profile over RUNS runs.
arm=$1; where=$2; p=$3; n=$4
Z=/zfs/rig-work/zero-copy; P=.zig-cache/trig-tests/packs/trig-pgo/bin
B=/zfs/trig-pup/runs/dec-$arm/$P
if [ $where = full ]; then d=$HOME/Data/Code/trig/misc/projects/$p; else d=$Z/empty/$p; fi
cd $d
taskset -c 15 perf record -q --call-graph lbr -c 20000 -e cpu_atom/cycles/u -o $Z/perf/$arm-$where-$p.data sh -c "for i in \$(seq 1 $n); do $B -p tsconfig.trig.json --noEmit --checkers 1 >/dev/null 2>&1; done"
