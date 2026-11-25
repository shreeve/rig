#!/bin/bash
# slot-rb-b.sh (no arguments): Rig - Final's revamp-base baseline on pup (Rig 645996606, owner-approved via Rig, 2026-11-24),
# on P-cores 0-11, in an ab slot Rig opened. About 40 minutes, part B of two: two release builds of Trig 950f14b3
# (trig-prog), total and Zig wall and size (cmds/trig-build.sh); one took 2,035 s on E-cores 12-19 in prep.sh.
# Output: /zfs/trig-pup/revamp-base/slot-b/. Run only in a slot Rig opened.
set -u
D=/zfs/trig-pup/revamp-base; O=$D/slot-b; RIG=$D/bin/rig
fatal() { echo "FATAL: $*"; exit 1; }
[ "$(sha256sum < $RIG | cut -c1-16)" = "$(cat $D/bin/rig.sha16)" ] || fatal "$RIG is not the build checked"
[ "$(git -C $D/rig rev-parse HEAD)" = 645996606074416e6141eb3d638aa05dacba7451 ] || fatal "rig/ is not at revamp-base"
for b in tasks actors net http; do
  [ "$(sha256sum < $D/bench-$b/rig-safe | cut -c1-16)" = "$(cat $D/bench-$b/rig-safe.sha16)" ] || fatal "bench-$b/rig-safe is not the build checked"
done
[ -x $D/bench-http/load ] || fatal "no http load generator"
grep -q "prep done" $D/prep.log || fatal "prep.sh has not finished"
case "$(/zfs/trig-pup/bin/pup-slot state)" in *slot=none*) fatal "no timing slot is open; only Rig opens slots" ;; esac
mkdir -p $O $D/tmp; export TMPDIR=$D/tmp NEXUS=$HOME/Data/Code/nexus/bin/nexus RIG_NO_CRASH_REPORT=1
s=$(date +%s); echo "# slot-rb-b start $(date +%T) state: $(/zfs/trig-pup/bin/pup-slot state)" | tee $O/state.log
taskset -c 0-11 $D/cmds/trig-build.sh $RIG $D/trig-prog 2 $O/trig > $O/trig-build.log 2>&1
echo "# slot-rb-b done $(date +%T), $(( $(date +%s) - s )) s; state: $(/zfs/trig-pup/bin/pup-slot state)" | tee -a $O/state.log
