#!/bin/sh
# prof.sh V N PROJ [CORE]: user cycles sampled on an E-core (default 18), N runs
# of v/V/bin on PROJ; prof/V.PROJ.ips, prof/V.PROJ.attr (attr.py), prof/V.PROJ.tsv.
set -u
W=/zfs/worktrees/rig/codegen-gap
v=$1 n=$2 proj=$3 core=${4:-18}
O=$W/prof; mkdir -p $O
cd $W/trig/misc/projects/$proj
: > $O/$v.$proj.ips
for i in $(seq 1 $n); do
  taskset -c $core perf record -q -e cpu_atom/cycles/u -c 3000017 -o $O/$v.$proj.data taskset -c $core $W/v/$v/bin -p tsconfig.trig.json --noEmit --singleThreaded > /dev/null 2>&1
  perf script -i $O/$v.$proj.data -F ip 2>/dev/null | sed "s/^ *//" >> $O/$v.$proj.ips
done
python3 $W/attr.py $W/v/$v/bin $O/$v.$proj.ips $O/$v.$proj.tsv > $O/$v.$proj.attr
echo "# done $v $proj $(wc -l < $O/$v.$proj.ips) samples"
