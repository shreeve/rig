#!/bin/bash
# board-workers.sh ROUNDS RAW: under 8 spinners, base with 10 workers, 6
# and 4 (RIG_WORKERS), and hyper, at 100k and 120k.
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/pollers
cd /Users/shreeve/Data/Code/worktrees/rig/poller-spread
$S/spin 8 1100 & P=$!; sleep 1
bench/mixed/bench-mixed --out $S/mixed --time-only --variants base,w6,w4,tokio --rates 100000,120000 --rounds $1 --raw $2
kill $P; wait $P 2>/dev/null
echo board-done
