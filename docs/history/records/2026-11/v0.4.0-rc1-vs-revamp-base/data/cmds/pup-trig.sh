#!/bin/bash
# pup-trig.sh: Trig's release builds on pup after pup-chain.sh's base 1: rc1, base, rc1, each under
# `cpuq drain -c 2 --prefer fast -t 60m` pinned to $CPUQ_CPUS (a 30-minute limit, which counts the wait, was too short).
set -u
D=/zfs/trig-pup/rc1-report; L=$D/logs; C=$D/cmds
export TMPDIR=$D/tmp RIG_NO_CRASH_REPORT=1 D L C
log() { echo "# $(date +%T) $*" >> $L/pup-chain.log; }
for sk in rc1:1 base:2 rc1:2; do s=${sk%:*}; k=${sk#*:}; export s k
  log "trig-build $s $k"
  cpuq drain -c 2 --prefer fast -t 60m --label rig:report -- bash -c 'echo "# cpus $CPUQ_CPUS"; taskset -c $CPUQ_CPUS $C/trig-build.sh $D/$s/bin/rig $D/trig-prog 1 $D/trig-$s-$k' > $L/pup-trig-build-$s-$k.log 2>&1
  log "trig-build $s $k rc=$?"
done
log "pup done"
