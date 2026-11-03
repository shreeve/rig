#!/bin/sh
# kern.sh: median user and kernel cycles of Trig (#244) and tsrs, 9 runs each, E-core 13
for p in ts-pattern zod3; do
  cd $HOME/Data/Code/trig/misc/projects/$p
  for r in 1 2 3 4 5 6 7 8 9; do
    taskset -c 13 perf stat -x, -e cpu_atom/cycles/u -e cpu_atom/cycles/k /tmp/lp4/n -p tsconfig.trig.json --noEmit --singleThreaded 2>&1 >/dev/null | awk -F, -v p=$p '{printf "%s trig %s %s\n", p, $3, $1}'
    RAYON_NUM_THREADS=1 TSRS_LAZY_DTS=0 taskset -c 13 perf stat -x, -e cpu_atom/cycles/u -e cpu_atom/cycles/k /zfs/trig-pup/tsrs/bin/tsrs -p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers 2>&1 >/dev/null | awk -F, -v p=$p '{printf "%s tsrs %s %s\n", p, $3, $1}'
  done
done | python3 -c "
import sys,statistics as st,collections
d=collections.defaultdict(list)
for l in sys.stdin:
    p,v,e,n=l.split(); d[(p,v,e)].append(int(n))
for k in sorted(d): print(k, round(st.median(d[k])/1e6,1), 'Mcycles')
"
