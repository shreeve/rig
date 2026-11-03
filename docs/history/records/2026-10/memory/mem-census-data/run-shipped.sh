#!/bin/sh
# run-shipped.sh BIN OUTDIR [EXTRA_ENV]: per project, tsc once, then BIN in both modes (shipped, go):
#   a plain run (stdout+stderr and exit status compared with tsc's),
#   a TSRS_MEM_SPLIT=1 run (stderr kept: the RSS split; plus any census env given as EXTRA_ENV),
#   an --extendedDiagnostics run (counts).
BIN=$1; OUT=$2; EXTRA=$3; mkdir -p $OUT
TSC=/zfs/trig-cache/trig-tsc-build/655f0268afaa43cde07b65b39782688463a99517/tsc/tsc
for proj in empty zod3 ts-pattern; do
  case $proj in empty) dir=/zfs/trig-cache/fe-proj/empty;; *) dir=/zfs/trig-pup/full/trig/misc/projects/$proj;; esac
  cd $dir
  [ -f $OUT/$proj.tsc.out ] || { $TSC -p tsconfig.trig.json --noEmit > $OUT/$proj.tsc.out 2>&1; echo $? > $OUT/$proj.tsc.status; }
  for mode in shipped go; do
    if [ $mode = go ]; then E="TSRS_LAZY_DTS=0"; A="--checkerAssignment go --noLazyMembers"; else E="X_UNUSED=0"; A=""; fi
    env RAYON_NUM_THREADS=1 $E taskset -c 12-19 $BIN -p tsconfig.trig.json --noEmit --singleThreaded $A > $OUT/$proj.$mode.out 2>&1; echo $? > $OUT/$proj.$mode.status
    env RAYON_NUM_THREADS=1 TSRS_MEM_SPLIT=1 $E $(echo "$EXTRA" | sed "s/@P@/$proj.$mode/g") taskset -c 12-19 $BIN -p tsconfig.trig.json --noEmit --singleThreaded $A > $OUT/$proj.$mode.memsplit.out 2> $OUT/$proj.$mode.memsplit; echo $? > $OUT/$proj.$mode.memsplit.status
    env RAYON_NUM_THREADS=1 $E taskset -c 12-19 $BIN -p tsconfig.trig.json --noEmit --singleThreaded --extendedDiagnostics $A > $OUT/$proj.$mode.diag 2>&1
    if cmp -s $OUT/$proj.$mode.out $OUT/$proj.tsc.out && cmp -s $OUT/$proj.$mode.status $OUT/$proj.tsc.status; then r=match; else r=DIFFERS; fi
    if cmp -s $OUT/$proj.$mode.memsplit.out $OUT/$proj.tsc.out && cmp -s $OUT/$proj.$mode.memsplit.status $OUT/$proj.tsc.status; then m=match; else m=DIFFERS; fi
    echo "$proj $mode: plain run $r tsc (status $(cat $OUT/$proj.$mode.status) vs $(cat $OUT/$proj.tsc.status)); census run stdout+status $m tsc"
  done
done
