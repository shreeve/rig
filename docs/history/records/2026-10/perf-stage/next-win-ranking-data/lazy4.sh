#!/bin/sh
P=/zfs/trig-pup/full/trig/misc/projects
SHIP=/zfs/trig-pup/tsrs-shipped/package/tsrs
N=${N:-4}
for proj in ${PROJS:-zod3 ts-pattern}; do
  cd $P/$proj
  for r in $(seq 1 $N); do
    for v in bar nounm; do
      case $v in
        bar) e="TSRS_X=0"; f=--noLazyMembers ;;
        nounm) e="TSRS_LAZY_UNMATCHED=0"; f= ;;
      esac
      /usr/bin/time -f "%M" -o /tmp/next-win/rss6.out taskset -c 16-19 perf stat --no-scale -x, -e cpu_atom/cycles/u,cpu_atom/cycles/k,cpu_atom/instructions/u -o /tmp/next-win/ps6.out env RAYON_NUM_THREADS=4 $e $SHIP -p tsconfig.trig.json --noEmit --checkerAssignment go $f --checkers 4 > /tmp/next-win/o6.$v 2>&1
      echo "$proj $r $v $(awk -F, "/^[0-9]/{printf \"%s \", \$1}" /tmp/next-win/ps6.out)$(tail -1 /tmp/next-win/rss6.out)"
      cmp -s /tmp/next-win/o6.bar /tmp/next-win/o6.$v || echo "# $proj $v output DIFFERS"
    done
  done
done
