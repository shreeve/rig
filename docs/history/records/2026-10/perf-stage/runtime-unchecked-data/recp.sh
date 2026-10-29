#!/bin/sh
# rec.sh V N_TS N_ZOD: user-instruction samples of check-bisect v/V (or $BIN)
# on core 6 (the kernel caps samples at 1000/s, so many runs), as "count ip".
set -u
W=/zfs/worktrees/rig/check-bisect
O=/zfs/worktrees/rig/runtime-unchecked/prof
B=${BIN:-$W/v/$1/bin}
for pn in ts-pattern:$2 zod3:$3; do
  proj=${pn%:*} n=${pn#*:}
  cd $W/projects/$proj
  : > $O/$1.$proj.raw
  i=0; while [ $i -lt $n ]; do
    perf record -q -m 64 -e cpu_core/instructions/upp -c 10000019 -o $O/tmp.data taskset -c 6 $B -p tsconfig.trig.json --noEmit --singleThreaded > /dev/null 2>&1
    perf script -F ip -i $O/tmp.data 2>/dev/null >> $O/$1.$proj.raw
    i=$((i+1))
  done
  sort $O/$1.$proj.raw | uniq -c | sort -rn > $O/$1.$proj.ips
  : > $O/$1.$proj.raw
  echo "$proj $(awk '{s+=$1}END{print s}' $O/$1.$proj.ips) samples, $(wc -l < $O/$1.$proj.ips) ips"
done
