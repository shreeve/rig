#!/bin/bash
# pup-chain.sh: pup's steps of the rc1 report, in /zfs/trig-pup/rc1-report, revamp-base (base/) and v0.4.0-rc1 (rc1/)
# interleaved. Timed steps run under `cpuq drain` pinned to $CPUQ_CPUS (-c 8 --prefer fast for builds and the
# concurrency benches, -c 2 --prefer fast otherwise); untimed ones under `cpuq run`.
set -u
D=/zfs/trig-pup/rc1-report; L=$D/logs; C=$D/cmds
mkdir -p $D/tmp; export TMPDIR=$D/tmp NEXUS=$HOME/Data/Code/nexus/bin/nexus RIG_NO_CRASH_REPORT=1 D L C
log() { echo "# $(date +%T) $*" >> $L/pup-chain.log; }
D2="cpuq drain -c 2 --prefer fast -t 20m --label rig:report --"; D8="cpuq drain -c 8 --prefer fast -t 20m --label rig:report --"
# 0. one untimed build of each, to warm the global Zig cache as the record's prep had
for s in base rc1; do log "warm $s"; (cd $D/$s && cpuq run --label rig:report -t 40m -- zig build) > $L/pup-warm-$s.log 2>&1; log "warm $s rc=$?"; done
# 1. builds, alternating, two each
for k in 1 2; do for s in base rc1; do
  log "build $s $k"; (cd $D/$s && $D8 bash -c 'taskset -c $CPUQ_CPUS $C/build-time.sh 1; echo "  cpus $CPUQ_CPUS"') >> $L/pup-build-$s.log 2>&1; log "build $s $k rc=$?"
done; done
# 2. bench builds (untimed)
for s in base rc1; do for b in tasks actors net http; do
  mkdir -p $D/bench-$s/$b; [ $b = http ] && cp -n /zfs/trig-pup/bench-remeasure-3f4564a4b/build/http/load $D/bench-$s/$b/load
  log "bench-build $s $b"; (cd $D/$s && RIG=$D/$s/bin/rig cpuq run --label rig:report -t 30m -- python3 bench/$b/bench-$b --variants rig-safe --out $D/bench-$s/$b --build-only) > $L/pup-bench-build-$s-$b.log 2>&1; log "bench-build $s $b rc=$?"
done; done
# 3. rig check --time on Trig: two sets of 7, alternating per run
for k in 1 2; do log "check set $k"; export k
  $D2 bash -c 'echo "# set $k cpus $CPUQ_CPUS"; for i in 1 2 3 4 5 6 7; do for s in base rc1; do taskset -c $CPUQ_CPUS $C/trig-check.sh $D/$s/bin/rig $D/trig-prog 1 >> $L/pup-check-$s-$k.log 2>&1; done; done' >> $L/pup-cpus.log 2>&1
  log "check set $k rc=$?"
done
# 4. concurrency benches
for b in tasks actors net http; do
  a=""; [ $b = http ] && a="--idle 10000"; export a b
  log "bench $b"
  $D8 bash -c 'echo "# bench $b cpus $CPUQ_CPUS"; for k in 1 2; do for s in base rc1; do (cd $D/$s && taskset -c $CPUQ_CPUS python3 bench/$b/bench-$b --variants rig-safe $a --out $D/bench-$s/$b --time-only) > $L/pup-bench-$b-$s-$k.log 2>&1; done; done' >> $L/pup-cpus.log 2>&1
  log "bench $b rc=$?"
done
# 5. Trig's release build, alternating, two each
for k in 1 2; do for s in base rc1; do
  export k s; log "trig-build $s $k"
  cpuq drain -c 2 --prefer fast -t 30m --label rig:report -- bash -c 'echo "# cpus $CPUQ_CPUS"; taskset -c $CPUQ_CPUS $C/trig-build.sh $D/$s/bin/rig $D/trig-prog 1 $D/trig-$s-$k' > $L/pup-trig-build-$s-$k.log 2>&1
  log "trig-build $s $k rc=$?"
done; done
log "pup done"
