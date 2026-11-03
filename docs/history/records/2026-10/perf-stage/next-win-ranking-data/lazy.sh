#!/bin/sh
# tsrs shipped, one thread, E-core 14: Go mode with lazy members off (the standing bar) vs on (as shipped);
# and lazy .d.ts binding on (default) vs off (TSRS_LAZY_DTS=0). cycles, instructions, max RSS.
P=/zfs/trig-pup/full/trig/misc/projects
SHIP=/zfs/trig-pup/tsrs-shipped/package/tsrs
N=${N:-5}
for proj in ${PROJS:-mitt neverthrow superstruct tiny-invariant zod3 ts-pattern}; do
  cd $P/$proj
  for r in $(seq 1 $N); do
    for v in bar lm nodts; do
      case $v in
        bar) set -- env RAYON_NUM_THREADS=1 $SHIP -p tsconfig.trig.json --noEmit --checkerAssignment go --noLazyMembers --singleThreaded ;;
        lm) set -- env RAYON_NUM_THREADS=1 $SHIP -p tsconfig.trig.json --noEmit --checkerAssignment go --singleThreaded ;;
        nodts) set -- env RAYON_NUM_THREADS=1 TSRS_LAZY_DTS=0 $SHIP -p tsconfig.trig.json --noEmit --checkerAssignment go --noLazyMembers --singleThreaded ;;
      esac
      /usr/bin/time -f "%M" -o /tmp/next-win/rss.out taskset -c 14 perf stat --no-scale -x, -e cpu_atom/cycles/u,cpu_atom/instructions/u -o /tmp/next-win/ps3.out "$@" > /tmp/next-win/o3.$v 2>&1
      c=$(awk -F, "/cycles/{print \$1}" /tmp/next-win/ps3.out); i=$(awk -F, "/instructions/{print \$1}" /tmp/next-win/ps3.out)
      echo "$proj $r $v $c $i $(tail -1 /tmp/next-win/rss.out)"
    done
    cmp -s /tmp/next-win/o3.bar /tmp/next-win/o3.lm || echo "# $proj lm output DIFFERS"
    cmp -s /tmp/next-win/o3.bar /tmp/next-win/o3.nodts || echo "# $proj nodts output DIFFERS"
  done
done
