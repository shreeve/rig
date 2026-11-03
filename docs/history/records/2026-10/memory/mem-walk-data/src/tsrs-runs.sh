#!/bin/sh
# tsrs-runs.sh: tsrs with a `bind end` memsplit point (program.rs), both modes, one thread,
# TSRS_MEM_SPLIT=1, on empty, zod3, ts-pattern; E-cores 12-19.
B=/zfs/trig-pup/mem-census/target/debug/tsrs; R=/zfs/trig-pup/memwalk/r/tsrs; mkdir -p $R
for proj in empty zod3 ts-pattern; do
  case $proj in empty) dir=/zfs/trig-cache/fe-proj/empty;; *) dir=/zfs/trig-pup/full/trig/misc/projects/$proj;; esac
  cd $dir
  for mode in shipped go; do
    if [ $mode = go ]; then E="TSRS_LAZY_DTS=0"; A="--checkerAssignment go --noLazyMembers"; else E="X_UNUSED=0"; A=""; fi
    env RAYON_NUM_THREADS=1 TSRS_MEM_SPLIT=1 $E taskset -c 12-19 $B -p tsconfig.trig.json --noEmit --singleThreaded $A > $R/$proj.$mode.out 2> $R/$proj.$mode.memsplit; echo $? > $R/$proj.$mode.status
    echo "$proj $mode status $(cat $R/$proj.$mode.status): $(grep '^tsrs mem split' $R/$proj.$mode.memsplit | tr '\n' ';')"
  done
done
