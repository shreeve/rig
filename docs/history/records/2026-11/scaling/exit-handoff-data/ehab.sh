#!/bin/bash
# ehab.sh OUT ROUNDS: Trig's PGO build on ts-pattern and zod3 at 1, 4 and 8 checkers on
# E-cores, each run under exitwatch, traced for its exit (watch: the wall a handoff
# would give and today's) or not (plain: today's alone, to check the tracing costs
# nothing); arms and checker counts shuffled each round.
set -u
OUT=$1; N=$2; B=/tmp/rw-eh; P=/zfs/trig-pup/full/trig/misc/projects; W=/zfs/rig-work/scaling/eh/exitwatch
: > $OUT
cores() { case $1 in 1) echo 12;; 4) echo 12-15;; 8) echo 12-19;; esac; }
for r in $(seq 1 $N); do
  for job in $(for proj in ts-pattern zod3; do for c in 1 4 8; do for a in watch plain; do echo $proj:$c:$a; done; done; done | shuf); do
    IFS=: read proj c a <<< "$job"
    cd $P/$proj
    if [ $a = plain ]; then e="env EXITWATCH_PLAIN=1"; else e=env; fi
    line=$($e taskset -c $(cores $c) $W $B/trig -p tsconfig.trig.json --noEmit --checkers $c 2>&1 >/dev/null | grep '^exitwatch')
    echo "r=$r proj=$proj c=$c arm=$a $line" >> $OUT
  done
done
