#!/bin/bash
# mac-trig2.sh: after mac-trig.sh, the rc1 Trig build that mac-t.sh's 20-minute drain cut (cpuq counts the wait in -t),
# under `cpuq drain -c 2 -t 60m`; then "t2 done" for mac-more.sh.
set -u
O=$HOME/Data/Code/Claude/rig/rig/rc1-report; L=$O/logs; C=$O/cmds; RB=$HOME/Data/Code/Claude/rig/rig/revamp-base
WR=$HOME/Data/Code/worktrees/rig/rc1m-rc1
export PATH=$HOME/.local/share/mise/installs/zig/0.17.0/bin:$PATH RIG_NO_CRASH_REPORT=1
log() { echo "# $(date +%T) $*" >> $L/mac-t.log; }
until grep -q "t done" $L/mac-t.log; do sleep 20; done
log "trig-build rc1 1"; cpuq drain -c 2 -t 60m --label rig:report -- $C/trig-build.sh $WR/bin/rig $RB/trig-prog 1 $O/mac-trig-rc1-1 > $L/mac-trig-build-rc1-1.log 2>&1; log "trig-build rc1 1 rc=$?"
log "t2 done"
