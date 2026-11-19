#!/bin/sh
# pup-job.sh: the x86-64 half of the code-alignment measurement, for pup
# (not run: Expert A had no pup time). Does a hot loop's fetch crossing a
# boundary cost on pup's Meteor Lake cores as qsort-mac's partition loop
# costs on the M5 (25-45% when its low push path crosses 4 KiB)? Offsets
# 1024-1151 by 1 (every 32- and 64-byte position of the loop top) and the
# loop top just before 4 KiB. Run inside a pup ab slot, on a P-core with
# its sibling idle; binaries on /zfs.
set -eu
d=/zfs/trig-pup/code-align; mkdir -p "$d"
python3 loopgen-x86.py $(seq 1024 1151) $(seq 4032 2 4094) > "$d/loop.c"
cc -O2 -o "$d/loop" "$d/loop.c"
for r in 1 2; do taskset -c 3 "$d/loop" 21 > "$d/loop-$r.txt"; done
