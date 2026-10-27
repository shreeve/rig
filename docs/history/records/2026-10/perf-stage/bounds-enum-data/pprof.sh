#!/bin/sh
# pprof.sh BIN TAG N: N runs of ts-pattern on core 6 under precise (PEBS) user
# instructions and cycles; per-run offsets summed into TAG.{instructions,cycles}.offs.
set -u
B=$1 T=$2 N=$3
W=/zfs/worktrees/rig/bounds-enum/prof; mkdir -p $W
cd $HOME/Data/Code/trig/misc/projects/ts-pattern
for ev in instructions cycles; do
  : > $W/$T.$ev.all
  for i in $(seq 1 $N); do
    perf record -q -e cpu_core/$ev/upp -c 2000003 -o $W/$T.$ev.$i.data taskset -c 6 $B -p tsconfig.trig.json --noEmit --singleThreaded > /dev/null 2>&1
    perf script -i $W/$T.$ev.$i.data -F ip,sym,symoff 2>/dev/null | awk "{print \$2}" >> $W/$T.$ev.all
    rm -f $W/$T.$ev.$i.data
  done
  sort $W/$T.$ev.all | uniq -c > $W/$T.$ev.offs; rm $W/$T.$ev.all
done
