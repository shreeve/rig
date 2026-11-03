#!/bin/sh
# Each arm's output on each project against tsc's at Trig's pin, stdout and
# exit status, on E-cores 18-19.
set -u
D=/zfs/worktrees/rig/standing-8
TSC=/zfs/trig-cache/trig-tsc-build/655f0268afaa43cde07b65b39782688463a99517/tsc/tsc
P=/zfs/trig-pup/full/trig/misc/projects
B=$D/bin
t="-p tsconfig.trig.json --noEmit"
GO="--checkerAssignment go --noLazyMembers"
O=$D/tsc-check; mkdir -p $O
for p in mitt neverthrow superstruct ts-pattern zod3 tiny-invariant; do
  cd $P/$p
  taskset -c 18,19 $TSC $t > $O/$p.tsc 2> /dev/null; echo "exit=$?" >> $O/$p.tsc
  for a in "trig1 $B/trig $t --singleThreaded" "trig4 $B/trig $t --checkers 4" "aa1 $B/aa $t --singleThreaded" "aa4 $B/aa $t --checkers 4" \
           "ids1 $B/ids $t --singleThreaded" "ids4 $B/ids $t --checkers 4" \
           "tsrs1 env RAYON_NUM_THREADS=1 $B/tsrs/tsrs $t --singleThreaded" "tsrs4 env RAYON_NUM_THREADS=4 $B/tsrs/tsrs $t --checkers 4" \
           "tsrsg1 env RAYON_NUM_THREADS=1 $B/tsrs/tsrs $t $GO --singleThreaded" "tsrsg4 env RAYON_NUM_THREADS=4 $B/tsrs/tsrs $t $GO --checkers 4"; do
    set -- $a; n=$1; shift
    taskset -c 18,19 "$@" > $O/$p.$n 2> /dev/null; echo "exit=$?" >> $O/$p.$n
    cmp -s $O/$p.tsc $O/$p.$n && echo "$p $n same as tsc" || echo "$p $n DIFFERS from tsc"
  done
  echo "$p tsc $(tail -1 $O/$p.tsc) lines $(wc -l < $O/$p.tsc)"
done
