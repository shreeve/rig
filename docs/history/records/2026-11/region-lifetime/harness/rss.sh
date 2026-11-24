#!/bin/bash
# rss.sh PROJECT C CPUS: peak RSS (KiB, /usr/bin/time %M) of the plain Trig main build and tsrs 0.23.0 (exact: --checkerAssignment go
# --noLazyMembers; and its default), 3 rounds, on CPUS. Rows to rss/PROJECT-cC.tsv. Inside cpuq.
set -u
R=~/cpuq/tmp/regionmodel; P=$1; C=$2; CPUS=$3; mkdir -p $R/rss; O=$R/rss/$P-c$C.tsv; : > $O
CO=~/cpuq/worktrees/trig-main/misc/corpus
case $P in
  typeorm) d=$CO/typeorm/packages/typeorm ;;
  date-fns) d=$CO/date-fns/pkgs/core ;;
  Compiler) d=$CO/typescript-benchmarking/cases/solutions/Compiler ;;
esac
cd $d; c=tsconfig.trig.json; [ -f $c ] || c=tsconfig.json
TS=$R/tsrs/package/tsrs; TG=$R/rel/trig
for r in 1 2 3; do
  for arm in trig tsrsG tsrsD; do
    if [ $C = 1 ]; then
      case $arm in trig) cmd="$TG -p $c --noEmit --singleThreaded" ;; tsrsG) cmd="env RAYON_NUM_THREADS=1 $TS -p $c --noEmit --singleThreaded --checkerAssignment go --noLazyMembers" ;; tsrsD) cmd="env RAYON_NUM_THREADS=1 $TS -p $c --noEmit --singleThreaded" ;; esac
    else
      case $arm in trig) cmd="$TG -p $c --noEmit --checkers $C" ;; tsrsG) cmd="$TS -p $c --noEmit --checkers $C --checkerAssignment go --noLazyMembers" ;; tsrsD) cmd="$TS -p $c --noEmit --checkers $C" ;; esac
    fi
    /usr/bin/time -o $R/rss/.t-$P-$C -f "%M" taskset -c $CPUS $cmd > $R/rss/.o-$P-$C 2>/dev/null; rc=$?
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" $P $C $arm $r "$(tail -1 $R/rss/.t-$P-$C)" "rc=$rc md5=$(md5sum < $R/rss/.o-$P-$C | cut -c1-8)" >> $O
  done
done
rm -f $R/rss/.t-$P-$C $R/rss/.o-$P-$C
