#!/bin/sh
# On pup: prof.sh V N [PROJ]: user cycles sampled every 4,000,037 on core 8,
# N runs of v/V/bin; prof/V.ips and the attribution prof/V.attr (attr.py
# of the standing record), and one LBR call-graph run, prof/V.lbr.data.
set -u
W=/zfs/worktrees/rig/trig-zig-ceiling
v=$1 n=$2 proj=${3:-ts-pattern}
O=$W/prof; mkdir -p $O
cd /zfs/trig-pup/full/trig/misc/projects/$proj
: > $O/$v.ips
for i in $(seq 1 $n); do
  perf record -q -e cpu_core/cycles/u -c 4000037 -o $O/$v.data taskset -c 8 $W/v/$v/bin -p tsconfig.trig.json --noEmit --singleThreaded > /dev/null 2>&1
  perf script -i $O/$v.data -F ip 2>/dev/null | sed "s/^ *//" >> $O/$v.ips
done
perf record -q -e cpu_core/cycles/u -c 400037 --call-graph lbr -o $O/$v.lbr.data taskset -c 8 $W/v/$v/bin -p tsconfig.trig.json --noEmit --singleThreaded > /dev/null 2>&1
python3 /zfs/worktrees/rig/tsrs-standing/attr.py $W/v/$v/bin $O/$v.ips $O/$v.tsv > $O/$v.attr
echo "# done $v $(wc -l < $O/$v.ips) samples"
