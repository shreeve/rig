#!/bin/sh
# The E-core record runs: natural level (all arms), then quiet (main, aa, l2).
cd /zfs/worktrees/rig/kernel-leads
sh ab.sh n.conf 60 empty mitt neverthrow superstruct > n-small.txt 2>&1
sh ab.sh n.conf 20 ts-pattern zod3 > n-big.txt 2>&1
sh ab.sh q.conf 60 empty mitt neverthrow superstruct > q-small.txt 2>&1
sh ab.sh q.conf 20 ts-pattern zod3 > q-big.txt 2>&1
echo done > full.done
