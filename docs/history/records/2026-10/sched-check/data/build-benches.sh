#!/bin/sh
# Build the small benchmarks (--release=fast) under each study variant.
S=${S:-$PWD}  # the study folder
for v in "$@"; do
  n=$(echo $v | tr ',=' '_-'); if [ "$v" = base ]; then e=""; else e=$v; fi
  for p in knucleotide-fast fannkuchredux fannkuchredux-fast tasks; do
    [ -x $S/bench/$p-$n ] && continue
    RIG_STUDY=$e RIG_OUT_DIR=$S/bench/out/$p-$n /Users/shreeve/Data/Code/rig/tools/heavy $S/bins/rig-study build --release=fast -o $S/bench/$p-$n $S/bench/src/$p.rig > $S/bench/build-$p-$n.log 2>&1 || echo "FAIL $p $v"
  done
done
