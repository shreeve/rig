#!/bin/sh
# stat.sh CORE N: per project and arm, the fewest of N runs of
# user instructions, user cycles, kernel cycles, faults, task-clock ms.
core=$1; n=$2
P=.zig-cache/trig-tests/packs/trig-pgo/bin
base=/zfs/trig-pup/runs/dec-base/$P; new=/zfs/trig-pup/runs/dec-new/$P
Z=/zfs/rig-work/zero-copy
ev=cpu_atom/instructions/u,cpu_atom/cycles/u,cpu_atom/cycles/k,page-faults,task-clock
case $core in 0|1|2|5|6|7|8|9|10|11) ev=cpu_core/instructions/u,cpu_core/cycles/u,cpu_core/cycles/k,page-faults,task-clock;; esac
for p in mitt neverthrow tiny-invariant superstruct zod3 ts-pattern; do
  for where in full empty; do
    if [ $where = full ]; then d=$HOME/Data/Code/trig/misc/projects/$p; else d=$Z/empty/$p; fi
    cd $d
    for arm in base new; do
      eval b=\$$arm
      for i in $(seq 1 $n); do
        taskset -c $core perf stat -x, -e $ev -o $Z/tmp.stat $b -p tsconfig.trig.json --noEmit --checkers 1 >/dev/null 2>&1
        awk -F, "{v[\$3]=\$1} END{for(k in v) if(k~/instructions/)i=v[k]; else if(k~/cycles.u/)u=v[k]; else if(k~/cycles.k/)kk=v[k]; else if(k~/page-faults/)f=v[k]; else if(k~/task-clock/)t=v[k]; printf \"%d %d %d %d %.2f\n\", i, u, kk, f, t}" $Z/tmp.stat
      done | sort -n -k2 | head -1 | awk -v p=$p -v w=$where -v a=$arm "{printf \"%-15s %-5s %-4s instr %6.1fM ucyc %6.1fM kcyc %6.1fM faults %6d task %6.1fms\n\", p, w, a, \$1/1e6, \$2/1e6, \$3/1e6, \$4, \$5}"
    done
  done
done
