#!/bin/bash
# hlrun.sh TAG PROJECT C CPUS: a tid heap-log run of hl/heap into out/TAG/, on CPUS (taskset), then site names. Inside cpuq.
set -u
R=~/cpuq/tmp/regionmodel; T=$1; P=$2; C=$3; CPUS=$4; O=$R/out/$T; mkdir -p $O
CO=~/cpuq/worktrees/trig-main/misc/corpus
case $P in
  typeorm) d=$CO/typeorm/packages/typeorm ;;
  date-fns) d=$CO/date-fns/pkgs/core ;;
  Compiler) d=$CO/typescript-benchmarking/cases/solutions/Compiler ;;
  *) echo "no project $P"; exit 2 ;;
esac
cd $d || exit 2
c=tsconfig.trig.json; [ -f $c ] || c=tsconfig.json
if [ "$C" = 1 ]; then a=--singleThreaded; else a="--checkers $C"; fi
s=$(date +%s)
env RIG_HEAP_LOG=$O/log.hlog /usr/bin/time -f "maxrss_kb %M" taskset -c $CPUS $R/hl/heap -p $c --noEmit $a > $O/out 2> $O/err
echo "$T run rc=$? $(md5sum < $O/out | cut -c1-8) $(stat -c %s $O/log.hlog) bytes $(( $(date +%s) - s )) s $(tail -1 $O/err)"
python3 $R/tools/hsym.py $R/hl/heap $O/log.hlog > /dev/null && echo "$T sitenames $(wc -l < $O/log.hlog.sitenames)"
