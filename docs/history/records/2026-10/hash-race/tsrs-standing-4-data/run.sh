#!/bin/sh
# run.sh: once the builds are done, 20 rounds of all six projects, then 20
# more of ts-pattern and zod3, then the diagnosis of Rig main's build.
W=/zfs/worktrees/rig/tsrs-standing-4
grep -q "^.* done$" $W/build.out || { echo "build did not finish" > $W/times.txt; exit 1; }
sh $W/time.sh 20 "ts-pattern zod3 neverthrow superstruct mitt tiny-invariant" > $W/times.txt 2> $W/time.err
echo finished >> $W/times.txt
sh $W/time.sh 20 > $W/times-b.txt 2> $W/time-b.err
echo finished >> $W/times-b.txt
sh $W/diag.sh $W/packs/af6e0e6bf-pgo/bin af6 20 > $W/diag-af6.out 2>&1
echo finished >> $W/diag-af6.out
