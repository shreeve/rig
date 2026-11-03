#!/bin/sh
# color-run.sh: the Table-coloring timing, 60 rounds on the small projects, 20 on the rest.
cd /zfs/trig-pup/tc
W=/zfs/trig-pup/tc/time-small sh /zfs/trig-pup/trial/time-ab.sh /zfs/trig-pup/tc/color.conf 60 "mitt neverthrow superstruct" > color-small.txt 2>&1
W=/zfs/trig-pup/tc/time-large sh /zfs/trig-pup/trial/time-ab.sh /zfs/trig-pup/tc/color.conf 20 "zod3 ts-pattern tiny-invariant" > color-large.txt 2>&1
