#!/bin/bash
# mac-trig.sh: Trig's release builds on the Mac after mac-t.sh's first pair: mac-t.sh was stopped during rc1's
# first build (which ran on), so base and rc1 follow under `cpuq drain -c 2 -t 60m`, then "t done" for mac-more.sh.
set -u
O=$HOME/Data/Code/Claude/rig/rig/rc1-report; L=$O/logs; C=$O/cmds; RB=$HOME/Data/Code/Claude/rig/rig/revamp-base
WR=$HOME/Data/Code/worktrees/rig/rc1m-rc1; M=$HOME/Data/Code/rig
export PATH=$HOME/.local/share/mise/installs/zig/0.17.0/bin:$PATH RIG_NO_CRASH_REPORT=1
log() { echo "# $(date +%T) $*" >> $L/mac-t.log; }
until ! pgrep -f "trig-build.sh .*mac-trig-rc1-1" > /dev/null; do sleep 10; done
RIGB=$(cd $M && tools/baseline 645996606); RIGR=$WR/bin/rig
for sk in base:2 rc1:2; do s=${sk%:*}; k=${sk#*:}; R=$RIGB; [ $s = rc1 ] && R=$RIGR
  log "trig-build $s $k"; cpuq drain -c 2 -t 60m --label rig:report -- $C/trig-build.sh $R $RB/trig-prog 1 $O/mac-trig-$s-$k > $L/mac-trig-build-$s-$k.log 2>&1; log "trig-build $s $k rc=$?"
done
log "t done"
