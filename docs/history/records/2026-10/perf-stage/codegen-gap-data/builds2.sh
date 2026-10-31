#!/bin/sh
# The second round, on Rig with #810 (a lent String or List held in a
# local; /zfs/trig-pup/rig-store-forward): hand (the safe edits, and
# inline functions' object parameters taken without `rig.rt`), then
# hashmap, one at a time. main810 is #810's own PGO build of the same Trig.
W=/zfs/worktrees/rig/codegen-gap
cd $W
export RIG=/zfs/trig-pup/rig-store-forward/bin/rig
sh mkpgo.sh hand810 $W/trig/src $W/hand810.patch --release
sh mkpgo.sh hashmap810 $W/trig-hm/src - --release
echo "$(date +%T) all done"
