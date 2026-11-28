#!/bin/bash
# pup-bench-more.sh: rounds 3-6 of the concurrency benches on pup, base and rc1 alternating, as pup-chain.sh step 4.
set -u
D=/zfs/trig-pup/rc1-report; L=$D/logs; export D L TMPDIR=$D/tmp RIG_NO_CRASH_REPORT=1
for b in tasks actors net http; do
  a=""; [ $b = http ] && a="--idle 10000"; export a b
  echo "# $(date +%T) more $b" >> $L/pup-chain.log
  cpuq drain -c 8 --prefer fast -t 20m --label rig:report -- bash -c 'echo "# more $b cpus $CPUQ_CPUS"; for k in 3 4 5 6; do for s in base rc1; do (cd $D/$s && taskset -c $CPUQ_CPUS python3 bench/$b/bench-$b --variants rig-safe $a --out $D/bench-$s/$b --time-only) > $L/pup-bench-$b-$s-$k.log 2>&1; done; done' >> $L/pup-cpus.log 2>&1
  echo "# $(date +%T) more $b rc=$?" >> $L/pup-chain.log
done
echo "# $(date +%T) more done" >> $L/pup-chain.log
