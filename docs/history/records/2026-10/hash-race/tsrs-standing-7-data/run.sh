#!/bin/sh
# standing-7's timing: 60 shuffled rounds on the 25 ms projects, 20 on the
# others, each set in its own results directory (time-ab.sh empties its
# runs file at start).
set -u
D=/zfs/worktrees/rig/standing-7
H=/zfs/trig-pup/trial/time-ab.sh
echo "start $(date +%T)" >> $D/run-status
S7W=$D/small sh $H $D/s7.conf 60 "mitt neverthrow superstruct" > $D/times-small.txt 2>&1
echo "small done $(date +%T)" >> $D/run-status
S7W=$D/large sh $H $D/s7.conf 20 "ts-pattern zod3 tiny-invariant" > $D/times-large.txt 2>&1
echo "done $(date +%T)" >> $D/run-status
