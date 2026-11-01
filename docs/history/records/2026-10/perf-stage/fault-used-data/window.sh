#!/bin/bash
R=/zfs/worktrees/rig-rust-ports/r45
mkdir -p /tmp/r45 && for a in m h z g; do cp $R/trig-$a /tmp/r45/$a; done && cp $R/trig-m /tmp/r45/a
cmp /tmp/r45/m /tmp/r45/a && echo 'A/A copy identical'
cd /zfs/trig-pup/trial
sh time-ab.sh $R/ab.conf 60 'mitt neverthrow superstruct' > $R/ab-small.txt 2>&1
sh time-ab.sh $R/ab.conf 20 'zod3 ts-pattern tiny-invariant' > $R/ab-large.txt 2>&1
echo WINDOW DONE $(date +%T)
