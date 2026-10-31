#!/bin/sh
W=/zfs/worktrees/rig/codegen-gap
cd $W
sh mkpgo.sh nochk $W/trig/src $W/old/unchecked-main.patch --release=fast
sh mkpgo.sh hand $W/trig/src $W/hand.patch --release
sh mkpgo.sh hashmap $W/trig-hm/src - --release
echo "$(date +%T) all done"
