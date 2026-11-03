#!/bin/sh
# rec.sh: per-run cycle totals (perf stat, 5 runs) and LBR call-graph samples, one checker,
# E-core 13, perf on other E-cores; Trig main 16b97ae against tsrs (TSRS_LAZY_DTS=0)
T=/tmp/gm2/trig; R=/zfs/trig-pup/tsrs/bin/tsrs; O=/tmp/gm2; P=/zfs/trig-pup/full/trig/misc/projects
TA="-p tsconfig.trig.json --noEmit --singleThreaded --checkers 1"
SA="-p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers"
for p in ts-pattern:12 zod3:50; do
  n=${p#*:}; p=${p%:*}; cd $P/$p
  for v in trig tsrs; do
    if [ $v = trig ]; then c="$T $TA"; else c="env RAYON_NUM_THREADS=1 TSRS_LAZY_DTS=0 $R $SA"; fi
    for i in 1 2 3 4 5; do taskset -c 12 perf stat -x, -e cpu_atom/cycles/u,cpu_atom/instructions/u -- taskset -c 13 $c >/dev/null 2>>$O/$p.$v.stat; done
    taskset -c 12,14,15,16,17,18,19 perf record -q -c 7000003 -e cpu_atom/cycles/u --call-graph lbr -o $O/$p.$v.data -- taskset -c 13 sh -c "i=0; while [ \$i -lt $n ]; do $c >/dev/null 2>&1; i=\$((i+1)); done"
    echo "$p $v recorded $(date +%T)"
  done
done
