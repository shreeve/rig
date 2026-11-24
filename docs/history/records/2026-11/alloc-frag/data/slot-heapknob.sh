#!/bin/bash
# slot-heapknob.sh (no arguments): the per-heap huge-page race (Trig session with Rig 2, 2026-11-24; Rig's terms: A' arm, RSS per count).
# Trig main 352c2faa in both builds, PGO on burst + BOLT on pup:
#   M = the pinned Rig b4d9e7247 (runs/b352/bin-bolt, as raced in slot 748);
#   K = Rig 2's scratch/heap-census 355e32b09 (the pin + census + RIG_HEAP_HUGE_MIN_MB, 21b484abf).
# Arms: M; R = K with the knob unset (A'); B = K with RIG_HEAP_HUGE_MIN_MB=64; P = K with RIG_HEAP_HUGE_MIN_MB=32.
# 16 board projects at c1/c2/c4/c8, 10 rounds, wall and peak RSS. Harness: phases-sweepBC5k.sh (a copy of Rig's BC5 that
# sets the knob in the B and P arms). About 45 minutes; stopped at 55. Output: /zfs/trig-pup/trial/heapknob/races/.
# Run only in a slot Rig opened, builds paused.
set -u
D=/zfs/trig-pup/trial/heapknob; H=$D/phases-sweepBC5k.sh; M=/zfs/trig-pup/runs/b352/bin-bolt; K=$D/hk352/bin-bolt
fatal() { echo "FATAL: $*"; exit 1; }
for b in $M $K; do [ -x $b ] && $b --version >/dev/null 2>&1 || fatal "$b missing or does not run"; done
[ "$(sha256sum < $M | cut -c1-16)" = 2eaafe6c80900a1f ] || fatal "$M is not slot 748's B"
[ "$(sha256sum < $K | cut -c1-16)" = "$(cat $D/hk352/bin-bolt.sha16)" ] || fatal "$K is not the build checked"
[ -f $H ] || fatal "no harness $H"
case "$(/zfs/trig-pup/bin/pup-slot state)" in *slot=none*) fatal "no timing slot is open; only Rig opens slots" ;; esac
mkdir -p $D/races; s=$(date +%s)
echo "# slot-heapknob start $(date +%T) M=$(sha256sum < $M | cut -c1-16) K=$(cat $D/hk352/bin-bolt.sha16) state: $(/zfs/trig-pup/bin/pup-slot state)"
PROJS="supabase-studio mikro-orm formbricks-web cal-diy xstate-main webpack Compiler Compiler-Unions next-packages-next next-root storybook nuxt playwright drizzle-orm typeorm date-fns" \
  ARMS="M1 R1 B1 P1 M2 R2 B2 P2 M4 R4 B4 P4 M8 R8 B8 P8" MAINBIN=$M RELOCBIN=$K BOLTBIN=$K PBIN=$K HUGE_B=64 HUGE_P=32 \
  OUT=$D/races/board16 TP=/tmp/tp-heapknob timeout 3300 bash $H 10
echo "# slot-heapknob done $(date +%T), $(( $(date +%s) - s )) s; state: $(/zfs/trig-pup/bin/pup-slot state)"
