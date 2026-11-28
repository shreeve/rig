#!/bin/bash
# mac-more.sh: after mac-t.sh, mac-trig.sh and mac-trig2.sh, rounds 3-6 of the concurrency benches (base and rc1 alternating, cpuq drain -c 8),
# then the check-speed guard of base and rc1 alternating, twice each (cpuq drain -c 2), from the rc1 worktree.
set -u
O=$HOME/Data/Code/Claude/rig/rig/rc1-report; L=$O/logs; RB=$HOME/Data/Code/Claude/rig/rig/revamp-base
WB=$HOME/Data/Code/worktrees/rig/rc1m-base; WR=$HOME/Data/Code/worktrees/rig/rc1m-rc1; M=$HOME/Data/Code/rig
export PATH=$HOME/.local/share/mise/installs/zig/0.17.0/bin:$PATH RIG_NO_CRASH_REPORT=1
log() { echo "# $(date +%T) $*" >> $L/mac-t.log; }
for i in $(seq 1 360); do grep -q "t2 done" $L/mac-t.log && break; sleep 20; done
RIGB=$(cd $M && tools/baseline 645996606); RIGR=$WR/bin/rig
for b in tasks actors net http; do
  a=""; [ $b = http ] && a="--idle 5000"
  log "more $b"
  cpuq drain -c 8 -t 20m --label rig:report -- bash -c "for k in 3 4 5 6; do (cd $WB && python3 bench/$b/bench-$b --variants rig-safe $a --out $RB/mac-bench/$b --time-only) > $L/mac-bench-$b-base-\$k.log 2>&1; (cd $WR && python3 bench/$b/bench-$b --variants rig-safe $a --out $O/mac-bench/$b --time-only) > $L/mac-bench-$b-rc1-\$k.log 2>&1; done"
  log "more $b rc=$?"
done
log "guard-check-ab"
(cd $WR && cpuq drain -c 2 -t 20m --label rig:report -- bash -c "for k in 1 2; do echo \"## base \$k\"; python3 bench/check/guard.py --rig $RIGB; echo \"## rc1 \$k\"; python3 bench/check/guard.py --rig $RIGR; done") > $L/mac-guard-check-ab.log 2>&1
log "guard-check-ab rc=$?"
log "more done"
