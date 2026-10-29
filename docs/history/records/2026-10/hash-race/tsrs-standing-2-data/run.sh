#!/bin/sh
# Waits for build.sh, then times 20 rounds.
W=/zfs/worktrees/rig/tsrs-standing-2
while kill -0 2818449 2>/dev/null; do sleep 30; done
grep -q "^.* done$" $W/build.out || { echo "build did not finish" >> $W/times.txt; exit 1; }
sh $W/time.sh 20 > $W/times.txt 2> $W/time.err
echo finished >> $W/times.txt
