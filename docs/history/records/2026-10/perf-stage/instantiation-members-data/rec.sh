#!/bin/sh
# rec.sh: LBR call-graph cycle samples, one checker, E-core 13, perf on other E-cores
T=/tmp/lp4/n; R=/zfs/trig-pup/tsrs/bin/tsrs; O=/tmp/i23; P=$HOME/Data/Code/trig/misc/projects
TA="-p tsconfig.trig.json --noEmit --singleThreaded --checkers 1"
SA="-p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers"
for p in ts-pattern:12 zod3:50; do
  n=${p#*:}; p=${p%:*}; cd $P/$p
  for v in trig tsrs; do
    if [ $v = trig ]; then c="$T $TA"; else c="env RAYON_NUM_THREADS=1 TSRS_LAZY_DTS=0 $R $SA"; fi
    taskset -c 12,14,15,16,17,18,19 perf record -q -c 7000003 -e cpu_atom/cycles/u --call-graph lbr -o $O/$p.$v.data -- taskset -c 13 sh -c "i=0; while [ \$i -lt $n ]; do $c >/dev/null 2>&1; i=\$((i+1)); done"
    echo "$p $v recorded $(date +%T)"
  done
done
