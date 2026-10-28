#!/bin/sh
# Waits (up to 60 minutes) until pup has 180 free 2 MiB blocks outside DMA,
# then times a, d, e, e2 quiet, 10 rounds.
W=/zfs/worktrees/rig/thp-frag
units() { awk '$4 != "DMA" { for (i = 14; i <= NF; i++) u += $i * 2^(i - 14) } END { print u + 0 }' /proc/buddyinfo; }
for i in $(seq 1 120); do
  [ $(units) -ge 180 ] && break
  echo "# $(date +%T) waiting: $(units) free 2 MiB blocks"
  sleep 30
done
echo "# $(date +%T) $(units) free 2 MiB blocks"
cd $W && V="a d e e2" MODES="quiet" sh time.sh 10
