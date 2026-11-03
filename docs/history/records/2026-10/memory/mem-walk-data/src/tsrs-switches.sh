#!/bin/sh
# tsrs-switches.sh: tsrs's laziness by switch. Shipped mode with one switch at Go's setting each,
# TSRS_MEM_SPLIT=1, one thread, E-cores 12-19; the split at check end.
B=/zfs/trig-pup/mem-census/target/debug/tsrs; R=/zfs/trig-pup/memwalk/r/switches; mkdir -p $R
for proj in empty zod3 ts-pattern; do
  case $proj in empty) dir=/zfs/trig-cache/fe-proj/empty;; *) dir=/zfs/trig-pup/full/trig/misc/projects/$proj;; esac
  cd $dir
  for arm in shipped lazydts0 nolazymembers goassign go; do
    E="X_UNUSED=0"; A=""
    case $arm in lazydts0) E="TSRS_LAZY_DTS=0";; nolazymembers) A="--noLazyMembers";; goassign) A="--checkerAssignment go";;
      go) E="TSRS_LAZY_DTS=0"; A="--checkerAssignment go --noLazyMembers";; esac
    env RAYON_NUM_THREADS=1 TSRS_MEM_SPLIT=1 $E taskset -c 12-19 $B -p tsconfig.trig.json --noEmit --singleThreaded --extendedDiagnostics $A > $R/$proj.$arm.out 2> $R/$proj.$arm.memsplit
    echo "$proj $arm $(grep -A20 'split: check end' $R/$proj.$arm.memsplit | grep 'split MiB' | head -1 | sed 's/.*split MiB: //') symbols $(grep '^Symbols' $R/$proj.$arm.out | awk '{print $2}')"
  done
done
