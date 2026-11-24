#!/bin/bash
# slot-thp.sh: huge-page threshold race (Rig 2's knob, RIG_HUGE_MIN_MB). phases-sweepBC6.sh, 16 projects + mui-docs, c1/c2/c4/c8.
# M = Trig d78aa3f3 PGO+BOLT on Rig 383a1b2b5 (b1r). B = the same Trig on Rig ce8f7f9ac (knob), default N=2 (A/A against M).
# X = knob at N=8 MiB, Y = knob at N=32 MiB. Wall and peak RSS. About 4 arms x 4 counts x 17 projects x 10 runs: ~40 min.
ROUNDS=${ROUNDS:-9}
T=/zfs/trig-pup/trial/t3; OLD=/zfs/trig-pup/runs/b1r/.zig-cache/trig-tests/packs/trig-pgo/bin-bolt; NEW=/zfs/trig-pup/thp-size/trig-knob-bolt; R=$T/races-thp; mkdir -p $R
for b in $NEW $OLD; do [ -x $b ] && $b --version >/dev/null 2>&1 || { echo "FATAL: $b missing or does not run"; exit 1; }; done
s=$(date +%s); echo "# slot-thp start $(date +%T) rounds=$ROUNDS M=$(sha256sum $OLD | cut -c1-12) B=$(sha256sum $NEW | cut -c1-12)"
ARMS="M1 B1 X1 Y1 M2 B2 X2 Y2 M4 B4 X4 Y4 M8 B8 X8 Y8" MAINBIN=$OLD BOLTBIN=$NEW OUT=$R/phases-r1 TP=/tmp/tp-boards-thp bash $T/phases-sweepBC6.sh $ROUNDS
echo "# phases done $(( $(date +%s)-s )) s"
