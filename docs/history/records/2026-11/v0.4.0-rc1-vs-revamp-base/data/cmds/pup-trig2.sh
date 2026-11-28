#!/bin/bash
# pup-trig2.sh: Trig's release builds on pup, base and rc1 side by side in one `cpuq drain -c 4 --prefer fast -t 60m`,
# each pinned to two of $CPUQ_CPUS (rc1 the first two and base the last two in round 2, swapped in round 3), so both
# meet the same cores and the same machine. (pup-chain.sh's base 1 ran alone on P-cores 1,3; a lone rc1 build got
# E-cores 12,14 and was stopped.)
set -u
D=/zfs/trig-pup/rc1-report; L=$D/logs; C=$D/cmds
export TMPDIR=$D/tmp RIG_NO_CRASH_REPORT=1 D L C
log() { echo "# $(date +%T) $*" >> $L/pup-chain.log; }
for k in 2 3; do export k
  log "trig-build pair $k"
  cpuq drain -c 4 --prefer fast -t 60m --label rig:report -- bash -c '
    IFS=, read -r a b c d <<< "$CPUQ_CPUS"; first=rc1; second=base; [ $k = 3 ] && { first=base; second=rc1; }
    echo "# cpus $CPUQ_CPUS: $first on $a,$b, $second on $c,$d"
    (echo "# cpus $a,$b"; taskset -c $a,$b $C/trig-build.sh $D/$first/bin/rig $D/trig-prog 1 $D/trig-$first-$k) > $L/pup-trig-build-$first-$k.log 2>&1 &
    (echo "# cpus $c,$d"; taskset -c $c,$d $C/trig-build.sh $D/$second/bin/rig $D/trig-prog 1 $D/trig-$second-$k) > $L/pup-trig-build-$second-$k.log 2>&1 &
    wait' >> $L/pup-cpus.log 2>&1
  log "trig-build pair $k rc=$?"
done
log "pup done"
