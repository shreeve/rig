#!/bin/sh
CORE=${CORE:-14}
P=/zfs/trig-pup/full/trig/misc/projects
LOC=/zfs/trig-pup/tsrs/bin/tsrs
SHIP=/zfs/trig-pup/tsrs-shipped/package/tsrs
N=${N:-5}
for proj in ${PROJS:-mitt zod3 tiny-invariant ts-pattern}; do
  cd $P/$proj
  for r in $(seq 1 $N); do
    for v in local shipped; do
      b=$LOC; [ $v = shipped ] && b=$SHIP
      taskset -c $CORE env RAYON_NUM_THREADS=1 perf stat --no-scale -x, -e cpu_atom/cycles/u,cpu_atom/instructions/u -o /tmp/next-win/ps2.out $b -p tsconfig.trig.json --noEmit --checkerAssignment go --noLazyMembers --singleThreaded > /tmp/next-win/o.$v 2>&1
      c=$(awk -F, "/cycles/{print \$1}" /tmp/next-win/ps2.out); i=$(awk -F, "/instructions/{print \$1}" /tmp/next-win/ps2.out)
      echo "$proj $r $v $c $i"
    done
  done
done
