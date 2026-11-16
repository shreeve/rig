#!/bin/bash
# count.sh OUTDIR: each counted server (count-base, count-a, count-b) at
# 120,000 a second over 5,000 idle connections, quiet and under 8
# spinners; each server's per-poller counts to OUTDIR/NAME-LOAD.txt.
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/pollers
D=$1; mkdir -p $D
ulimit -n 20000
port=18801
for load in quiet spin; do
  P=
  if [[ $load == spin ]]; then $S/spin 8 200 & P=$!; sleep 1; fi
  for v in count-base count-a count-b; do
    rm -f $D/$v-$load.txt
    RIG_POLL_COUNT=$D/$v-$load.txt RIG_HTTP_IDLE_MS=600000 RIG_SCHED_STATS=1 $S/mixed/$v 127.0.0.1:$port > /dev/null 2> $D/$v-$load.stats & V=$!
    sleep 0.5
    $S/mixed/load -addr 127.0.0.1:$port -rates 120000 -conns 128 -duration 5s -warmup 1s -mix 4 -idle 5000 > $D/$v-$load.load 2>&1
    kill $V; wait $V 2>/dev/null
    port=$((port+1))
  done
  [[ -n $P ]] && { kill $P; wait $P 2>/dev/null; }
done
echo done
