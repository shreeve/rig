#!/bin/sh
# Each arm's output on each project against tsc's at Trig's pin (the light
# gate's tsc), stdout and exit status, on the E-cores.
set -u
D=/zfs/worktrees/rig/standing-7
TSC=/zfs/trig-cache/trig-tsc-build/655f0268afaa43cde07b65b39782688463a99517/tsc/tsc
P=/zfs/trig-pup/full/trig/misc/projects
B=/tmp/s7
t="-p tsconfig.trig.json --noEmit"
g="--checkerAssignment go --noLazyMembers"
O=$D/tsc-check; mkdir -p $O
for p in mitt neverthrow superstruct ts-pattern zod3 tiny-invariant; do
  cd $P/$p
  taskset -c 12-19 $TSC $t > $O/$p.tsc 2> /dev/null; echo "exit=$?" >> $O/$p.tsc
  for a in "trig1 $B/trig $t --singleThreaded" "trig4 $B/trig $t --checkers 4" "aa1 $B/aa $t --singleThreaded" "aa4 $B/aa $t --checkers 4" \
           "nolib1 $B/nolib $t --singleThreaded" "nolib4 $B/nolib $t --checkers 4" \
           "tsrs1 env RAYON_NUM_THREADS=1 $B/tsrs/tsrs $t --singleThreaded" "tsrs4 env RAYON_NUM_THREADS=4 $B/tsrs/tsrs $t --checkers 4" \
           "tsrsg1 env RAYON_NUM_THREADS=1 $B/tsrs/tsrs $t $g --singleThreaded" "tsrsg4 env RAYON_NUM_THREADS=4 $B/tsrs/tsrs $t $g --checkers 4"; do
    set -- $a; n=$1; shift
    taskset -c 12-19 "$@" > $O/$p.$n 2> /dev/null; echo "exit=$?" >> $O/$p.$n
    cmp -s $O/$p.tsc $O/$p.$n && echo "$p $n same as tsc" || echo "$p $n DIFFERS from tsc"
  done
  echo "$p tsc $(tail -1 $O/$p.tsc) lines $(wc -l < $O/$p.tsc)"
done
