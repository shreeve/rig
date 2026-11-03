#!/bin/sh
# Build Trig (release) under each study variant of rig-study, one at a time through tools/heavy.
S=${S:-$PWD}  # the study folder
cd $S/trig-src
for v in "$@"; do
  n=$(echo $v | tr ',=' '_-')
  if [ "$v" = base ]; then e=""; else e=$v; fi
  [ -x $S/bins/trig-$n ] && continue
  t0=$(date +%s)
  RIG_STUDY=$e RIG_OUT_DIR=$S/out-$n /Users/shreeve/Data/Code/rig/tools/heavy $S/bins/rig-study build --release -o $S/bins/trig-$n main.rig > $S/data/build-$n.log 2>&1
  echo "$v status=$? $(( $(date +%s) - t0 ))s" >> $S/data/builds.txt
done
