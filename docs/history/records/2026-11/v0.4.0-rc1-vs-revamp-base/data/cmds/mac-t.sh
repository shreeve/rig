#!/bin/bash
# mac-t.sh: the Mac's timed steps of the rc1 report, revamp-base (645996606) and v0.4.0-rc1 (0764e091f) interleaved,
# each under `cpuq drain` (-c 8 for builds and the concurrency benches, -c 2 otherwise), Zig 0.17.0 first on PATH.
set -u
O=$HOME/Data/Code/Claude/rig/rig/rc1-report; L=$O/logs; C=$O/cmds; RB=$HOME/Data/Code/Claude/rig/rig/revamp-base
WB=$HOME/Data/Code/worktrees/rig/rc1m-base; WR=$HOME/Data/Code/worktrees/rig/rc1m-rc1; M=$HOME/Data/Code/rig
export PATH=$HOME/.local/share/mise/installs/zig/0.17.0/bin:$PATH NEXUS=$HOME/Data/Code/nexus/bin/nexus RIG_NO_CRASH_REPORT=1
log() { echo "# $(date +%T) $*" >> $L/mac-t.log; }
D2="cpuq drain -c 2 -t 20m --label rig:report --"; D8="cpuq drain -c 8 -t 20m --label rig:report --"
# 1. builds, base and rc1 alternating, two each
for k in 1 2; do
  for s in base rc1; do W=$WB; [ $s = rc1 ] && W=$WR
    log "build $s $k"; (cd $W && $D8 $C/build-time.sh 1) >> $L/mac-build-$s.log 2>&1; log "build $s $k rc=$?"
  done
done
RIGB=$(cd $M && tools/baseline 645996606); RIGR=$WR/bin/rig
log "RIGB=$RIGB RIGR=$RIGR"
# 2. rig check --time on Trig: two sets of 7, each run alternating base and rc1
for k in 1 2; do
  log "check set $k"
  $D2 bash -c "for i in 1 2 3 4 5 6 7; do $C/trig-check.sh $RIGB $RB/trig-prog 1 >> $L/mac-check-base-$k.log 2>&1; $C/trig-check.sh $RIGR $RB/trig-prog 1 >> $L/mac-check-rc1-$k.log 2>&1; done"
  log "check set $k rc=$?"
done
# 3. the check-speed guard at rc1, twice
log "guard-check"; (cd $WR && $D2 bash -c "python3 bench/check/guard.py --rig $RIGR; echo '## run 2'; python3 bench/check/guard.py --rig $RIGR") > $L/mac-guard-check.log 2>&1; log "guard-check rc=$?"
# 4. concurrency benches (wait for mac-g's rc1 bench builds, at most 40 min)
for i in $(seq 1 240); do grep -q "bench-build-http rc=" $L/mac-g.log 2>/dev/null && break; sleep 10; done
for b in tasks actors net http; do
  a=""; [ $b = http ] && a="--idle 5000"
  log "bench $b"
  $D8 bash -c "for k in 1 2; do (cd $WB && python3 bench/$b/bench-$b --variants rig-safe $a --out $RB/mac-bench/$b --time-only) > $L/mac-bench-$b-base-\$k.log 2>&1; (cd $WR && python3 bench/$b/bench-$b --variants rig-safe $a --out $O/mac-bench/$b --time-only) > $L/mac-bench-$b-rc1-\$k.log 2>&1; done"
  log "bench $b rc=$?"
done
# 5. Trig's release build, base and rc1 alternating, two each
for k in 1 2; do
  for s in base rc1; do R=$RIGB; [ $s = rc1 ] && R=$RIGR
    log "trig-build $s $k"; $D2 $C/trig-build.sh $R $RB/trig-prog 1 $O/mac-trig-$s-$k > $L/mac-trig-build-$s-$k.log 2>&1; log "trig-build $s $k rc=$?"
  done
done
log "t done"
