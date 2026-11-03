#!/bin/sh
# perf stat, one checker, E-core $CORE, plain vs PGO (standing-6 source 806e0a1), alternated
CORE=${CORE:-14}
P=/zfs/trig-pup/full/trig/misc/projects
PLAIN=/zfs/worktrees/rig/four-checkers/ck0/trig-plain
PGO=/zfs/worktrees/rig/standing-6/trig/bin
N=${N:-5}
for proj in ${PROJS:-mitt neverthrow superstruct zod3 tiny-invariant ts-pattern}; do
  cd $P/$proj
  for r in $(seq 1 $N); do
    for v in plain pgo; do
      b=$PLAIN; [ $v = pgo ] && b=$PGO
      taskset -c $CORE perf stat --no-scale -x, -e cpu_atom/cycles/u,cpu_atom/instructions/u -o /tmp/next-win/ps.out $b -p tsconfig.trig.json --noEmit --singleThreaded > /dev/null 2>&1
      c=$(awk -F, "/cycles/{print \$1}" /tmp/next-win/ps.out); i=$(awk -F, "/instructions/{print \$1}" /tmp/next-win/ps.out)
      echo "$proj $r $v $c $i"
    done
  done
done
