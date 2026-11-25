#!/bin/bash
# mac-chain.sh: the Mac's timed steps of the revamp-base baseline, one after another, in the revamp-base worktree,
# with Zig 0.17.0 first on PATH. Timing runs hold the Mac's claim (tools/mac-claim, one board each); builds and the
# instruction guards run through tools/heavy. Each step's log is logs/mac-<step>.log; a failed step is noted and the
# chain goes on.
set -u
R=$HOME/Data/Code/Claude/rig/rig/revamp-base; W=$HOME/Data/Code/worktrees/rig/revamp-base-record; L=$R/logs
export PATH=$HOME/.local/share/mise/installs/zig/0.17.0/bin:$PATH NEXUS=$HOME/Data/Code/nexus/bin/nexus RIG_NO_CRASH_REPORT=1
cd $W || exit 1
step() { local name=$1; shift; echo "# $(date +%T) $name: $*" >> $L/mac-chain.log; "$@" > $L/mac-$name.log 2>&1; echo "# $(date +%T) $name rc=$?" >> $L/mac-chain.log; }
step build tools/mac-claim rb-build $R/cmds/build-time.sh 2
export RIG=$W/bin/rig
for b in tasks actors net http; do step bench-build-$b tools/heavy python3 bench/$b/bench-$b --variants rig-safe --out $R/mac-bench/$b --build-only; done
for g in json hash text print; do for k in 1 2; do step guard-$g-$k tools/heavy python3 bench/$g/guard.py; done; done
step guard-check tools/mac-claim rb-check-guard bash -c "python3 bench/check/guard.py; echo '## run 2'; python3 bench/check/guard.py"
step trig-check tools/mac-claim rb-trig-check bash -c "$R/cmds/trig-check.sh $RIG $R/trig-prog 7 > $L/mac-check-1.log 2>&1; $R/cmds/trig-check.sh $RIG $R/trig-prog 7 > $L/mac-check-2.log 2>&1"
step trig-build-1 tools/mac-claim --minutes 20 rb-trig-build-1 $R/cmds/trig-build.sh $RIG $R/trig-prog 1 $R/mac-trig-1
step trig-build-2 tools/mac-claim --minutes 20 rb-trig-build-2 $R/cmds/trig-build.sh $RIG $R/trig-prog 1 $R/mac-trig-2
step bench-ta tools/mac-claim rb-bench-tasks-actors bash -c "for b in tasks actors; do for k in 1 2; do python3 bench/\$b/bench-\$b --variants rig-safe --out $R/mac-bench/\$b --time-only > $L/mac-bench-\$b-\$k.log 2>&1; done; done"
step bench-nh tools/mac-claim rb-bench-net-http bash -c "for k in 1 2; do python3 bench/net/bench-net --variants rig-safe --out $R/mac-bench/net --time-only > $L/mac-bench-net-\$k.log 2>&1; done; for k in 1 2; do python3 bench/http/bench-http --variants rig-safe --idle 5000 --out $R/mac-bench/http --time-only > $L/mac-bench-http-\$k.log 2>&1; done"
echo "# $(date +%T) chain done" >> $L/mac-chain.log
