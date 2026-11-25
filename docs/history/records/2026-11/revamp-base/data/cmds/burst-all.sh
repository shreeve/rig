#!/bin/bash
# revamp-base-all.sh: Rig's full suite (`swarm test/rig.rip all`) at revamp-base (645996606), in a worktree of ~/src/rig.
# Run it inside cpuq:  cpuq run --label rig:revamp-base --cores 64 -- ~/cpuq/tmp/revamp-base-all.sh
. ~/cpuq/tmp/setup1123/env.sh
unset RIG RIG_PIN_DIR RIG_NO_CRASH_REPORT
set -u
export NEXUS=$HOME/src/nexus/bin/nexus
W=~/cpuq/worktrees/rig-645996606; L=~/cpuq/worktrees/rig-645996606-all${RUN:-}.log
git -C ~/src/rig fetch -q origin --tags
[ -d $W ] || git -C ~/src/rig worktree add -q --detach $W 645996606
cd $W && [ "$(git rev-parse HEAD)" = 645996606074416e6141eb3d638aa05dacba7451 ] || { echo "not at revamp-base"; exit 1; }
echo "# $(date +%T) build" > $L
zig build -Dnexus=$HOME/src/nexus/bin/nexus >> $L 2>&1 || { echo "build failed"; exit 1; }
s=$(date +%s); echo "# $(date +%T) swarm all -w 64" >> $L
swarm test/rig.rip all -w 64 -q >> $L 2>&1; rc=$?
echo "# $(date +%T) swarm rc=$rc wall_s=$(( $(date +%s) - s )) done=$(ls .swarm/done | wc -l) died=$(ls .swarm/died 2>/dev/null | wc -l)" >> $L
tail -5 $L
