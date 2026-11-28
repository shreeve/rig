#!/bin/bash
# mac-g.sh: the Mac's untimed steps of the rc1 report (cpuq run): the rc1 baseline rig, the rc1 bench builds,
# the json/hash/text instruction guards twice each, and the structure count.
set -u
O=$HOME/Data/Code/Claude/rig/rig/rc1-report; L=$O/logs; W=$HOME/Data/Code/worktrees/rig/rc1m-rc1; M=$HOME/Data/Code/rig
export PATH=$HOME/.local/share/mise/installs/zig/0.17.0/bin:$PATH NEXUS=$HOME/Data/Code/nexus/bin/nexus RIG_NO_CRASH_REPORT=1
step() { local name=$1; shift; echo "# $(date +%T) $name: $*" >> $L/mac-g.log; "$@" > $L/mac-$name.log 2>&1; echo "# $(date +%T) $name rc=$?" >> $L/mac-g.log; }
RIGR=$(cd $M && cpuq run --label rig:report -t 30m -- tools/baseline 0764e091f 2>>$L/mac-g.log | tail -1)
echo "# RIGR=$RIGR" >> $L/mac-g.log
cd $W || exit 1
export RIG=$RIGR
for b in tasks actors net http; do step bench-build-$b cpuq run --label rig:report -t 20m -- python3 bench/$b/bench-$b --variants rig-safe --out $O/mac-bench/$b --build-only; done
for g in json hash text; do for k in 1 2; do step guard-$g-$k cpuq run --label rig:report -t 30m -- python3 bench/$g/guard.py; done; done
step structure python3 $O/cmds/structure.py
echo "# $(date +%T) g done" >> $L/mac-g.log
