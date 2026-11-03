#!/bin/sh
P=/zfs/trig-pup/full/trig/misc/projects
SHIP=/zfs/trig-pup/tsrs-shipped/package/tsrs
N=${N:-3}
for proj in ${PROJS:-tiny-invariant zod3 ts-pattern superstruct}; do
  cd $P/$proj
  for r in $(seq 1 $N); do
    for v in bar lm nounm notup; do
      case $v in
        bar) e="TSRS_X=0"; f=--noLazyMembers ;;
        lm) e="TSRS_X=0"; f= ;;
        nounm) e="TSRS_LAZY_UNMATCHED=0"; f= ;;
        notup) e="TSRS_LAZY_TUPLES=0"; f= ;;
      esac
      /usr/bin/time -f "%M" -o /tmp/next-win/rss4.out taskset -c 14 perf stat --no-scale -x, -e cpu_atom/cycles/u,cpu_atom/instructions/u -o /tmp/next-win/ps4.out env RAYON_NUM_THREADS=1 $e $SHIP -p tsconfig.trig.json --noEmit --checkerAssignment go $f --singleThreaded > /tmp/next-win/o4.$v 2>&1
      c=$(awk -F, "/cycles/{print \$1}" /tmp/next-win/ps4.out); i=$(awk -F, "/instructions/{print \$1}" /tmp/next-win/ps4.out)
      echo "$proj $r $v $c $i $(tail -1 /tmp/next-win/rss4.out)"
      cmp -s /tmp/next-win/o4.bar /tmp/next-win/o4.$v || echo "# $proj $v output DIFFERS"
    done
  done
done
