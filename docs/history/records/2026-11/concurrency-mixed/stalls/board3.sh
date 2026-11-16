#!/bin/bash
# Overload on a shared machine: each server at 120k and 160k offered, with
# no background load and with SPIN spinning threads; then Rig and hyper
# sampled at 160k under the spinners.
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/stall
D=$1; SPIN=${SPIN:-8}; mkdir -p $D
cd /Users/shreeve/Data/Code/worktrees/rig/stall-trace
B="bench/mixed/bench-mixed --out $S/build --time-only --rates 120000,160000"
$B --rounds 2 --raw $D/quiet.jsonl > $D/quiet.txt 2>&1
$S/spin $SPIN 400 & P=$!
$B --rounds 3 --raw $D/spin.jsonl > $D/spin.txt 2>&1
for v in rig-safe tokio; do
  RIG_HTTP_IDLE_MS=600000 $S/build/$v 127.0.0.1:18790 > /dev/null & V=$!
  sleep 0.5
  $S/build/load -addr 127.0.0.1:18790 -rates 160000 -duration 8s -warmup 1s -idle 5000 > $D/sampled-$v.txt 2>&1 & L=$!
  sleep 6
  sample $V 3 -file $D/sample-$v.txt > /dev/null 2>&1
  wait $L; kill $V; wait $V 2>/dev/null
done
kill $P 2>/dev/null; wait $P 2>/dev/null
echo done >> $D/spin.txt
