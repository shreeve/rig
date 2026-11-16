#!/bin/bash
# One stall board: the canary beside bench-mixed, every Rig run traced,
# top sampling the machine each second; CONTROL=N first runs the canary
# alone for N seconds, with no load.
# board.sh DIR ROUNDS RATES [VARIANTS]
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/stall
D=$1; mkdir -p $D
cd /Users/shreeve/Data/Code/worktrees/rig/stall-trace
top -l 1150 -s 1 -n 10 -o cpu -stats pid,cpu,th,state,command > $D/top.log 2>&1 &
T=$!
if [[ -n $CONTROL ]]; then $S/canary $CONTROL > $D/control.log; fi
$S/canary 1080 > $D/canary.log &
C=$!
if [[ $2 -gt 0 ]]; then
STALL_DIR=$D STALL_TRACE=${STALL_TRACE:-1} bench/mixed/bench-mixed --out $S/build --time-only --rounds $2 \
  --rates $3 --variants ${4:-rig-safe,tokio,go} --raw $D/raw.jsonl > $D/run.txt 2>&1
fi
kill $C $T 2>/dev/null; wait $C $T 2>/dev/null
echo done >> $D/run.txt
