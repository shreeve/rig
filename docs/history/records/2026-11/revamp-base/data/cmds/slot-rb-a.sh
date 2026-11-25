#!/bin/bash
# slot-rb-a.sh (no arguments): Rig - Final's revamp-base baseline on pup (Rig 645996606, owner-approved via Rig, 2026-11-24),
# on P-cores 0-11, in an ab slot Rig opened. About 25 minutes, part A of two:
#   1. two clean `zig build`s of Rig in rig/ (cmds/build-time.sh), wall, warnings, size;
#   2. `rig check --time` of Trig 950f14b3 (trig-prog), best of 7, two sets, peak RSS (cmds/trig-check.sh);
#   3. bench tasks, actors, net and http, rig-safe, --time-only twice each (bench-<name>, built by prep.sh).
# Output: /zfs/trig-pup/revamp-base/slot-a/. Run only in a slot Rig opened.
set -u
D=/zfs/trig-pup/revamp-base; O=$D/slot-a; RIG=$D/bin/rig
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
s=$(date +%s); echo "# slot-rb-a start $(date +%T) state: $(/zfs/trig-pup/bin/pup-slot state)" | tee $O/state.log
P="taskset -c 0-11"
(cd $D/rig && $P $D/cmds/build-time.sh 2) > $O/build.log 2>&1
for k in 1 2; do $P $D/cmds/trig-check.sh $RIG $D/trig-prog 7 > $O/check-$k.log 2>&1; done
for b in tasks actors net http; do
  for k in 1 2; do RIG=$RIG $P python3 $D/rig/bench/$b/bench-$b --variants rig-safe --out $D/bench-$b --time-only > $O/bench-$b-$k.log 2>&1; done
done
echo "# slot-rb-a done $(date +%T), $(( $(date +%s) - s )) s; state: $(/zfs/trig-pup/bin/pup-slot state)" | tee -a $O/state.log
