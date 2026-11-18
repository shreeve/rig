#!/bin/bash
# count2.sh OUTDIR: count2-base and count2-b at 60k and 120k quiet and 120k
# under 8 spinners, 5,000 idle connections; per-worker counts to OUTDIR.
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/pollers
D=$1; mkdir -p $D; ulimit -n 20000; port=18871
one() { # VARIANT RATE TAG
  rm -f $D/$1-$3.txt
  RIG_POLL_COUNT=$D/$1-$3.txt RIG_HTTP_IDLE_MS=600000 $S/mixed/$1 127.0.0.1:$port > /dev/null 2>&1 & V=$!
  sleep 0.5
  $S/mixed/load -addr 127.0.0.1:$port -rates $2 -conns 128 -duration 5s -warmup 1s -mix 4 -idle 5000 > $D/$1-$3.load 2>&1
  kill $V; wait $V 2>/dev/null; port=$((port+1))
}
for v in count2-base count2-b; do one $v 60000 60k; one $v 120000 120k; done
$S/spin 8 100 & P=$!; sleep 1
for v in count2-base count2-b; do one $v 120000 120k-spin; done
kill $P; wait $P 2>/dev/null
echo done
