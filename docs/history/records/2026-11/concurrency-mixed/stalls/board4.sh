#!/bin/bash
# Traced Rig at 120k under 8 spinning threads, the canary beside.
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/stall
D=$1; mkdir -p $D
cd /Users/shreeve/Data/Code/worktrees/rig/stall-trace
$S/spin 8 150 & P=$!
$S/canary 150 > $D/canary.log & C=$!
STALL_DIR=$D STALL_TRACE=1 bench/mixed/bench-mixed --out $S/build --time-only --rounds 2 --variants rig-safe,tokio \
  --rates 120000,120000,120000 --raw $D/raw.jsonl > $D/run.txt 2>&1
kill $P $C 2>/dev/null; wait $P $C 2>/dev/null
echo done >> $D/run.txt
