#!/bin/bash
# trig-ab.sh S OUT: Trig built without and with align(64) (buildtrig.sh)
# raced by Trig's tools/bench/ab at one checker (--singleThreaded), 20
# shuffled rounds, an A/A arm, instructions and cycles; then qsort-mac's
# s0, s1 and the shifted s0 under /usr/bin/time -l. Run it inside
# tools/mac-claim (claim.sh). Not run in this round: the Mac never went
# quiet (load 9 to 15) in the hour left.
S=$1; OUT=$2
cd ~/Data/Code/trig
python3 tools/bench/ab --rounds 20 --instructions --json "$OUT/trig-ab.json" base=$S/trig/bin-base a64=$S/trig/bin-a64 > "$OUT/trig-ab.txt" 2>&1
for i in 1 2 3 4 5; do for p in w/s0 w/s1 fix/s0; do echo "$p"; RIG_WORKERS=1 /usr/bin/time -l $S/$p 2>&1 | grep -E "qsort|instructions retired|cycles elapsed"; done; done > "$OUT/counts-s0-s1.txt"
