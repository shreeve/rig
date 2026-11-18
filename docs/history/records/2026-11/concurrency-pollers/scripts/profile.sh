#!/bin/bash
# profile.sh OUTDIR: base and spread at 60k and 120k quiet, and base and
# tokio at 120k under 8 spinners: the scheduler's counts (RIG_SCHED_STATS,
# printed as SIGINT ends main) and a 3 s `sample` mid-window.
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/pollers
D=$1; mkdir -p $D; ulimit -n 20000; port=18841
one() { # NAME VARIANT RATE
  RIG_HTTP_IDLE_MS=600000 RIG_SCHED_STATS=1 $S/mixed/$2 127.0.0.1:$port > /dev/null 2> $D/$1.stats & V=$!
  sleep 0.5
  $S/mixed/load -addr 127.0.0.1:$port -rates $3 -conns 128 -duration 6s -warmup 1s -mix 4 -idle 5000 > $D/$1.load 2>&1 & L=$!
  sleep 5
  sample $V 3 -file $D/$1.sample > /dev/null 2>&1
  wait $L
  kill -INT $V; sleep 1; kill $V 2>/dev/null; wait $V 2>/dev/null
  port=$((port+1))
}
one base-60k base 60000
one spread-60k spread 60000
one base-120k base 120000
one spread-120k spread 120000
$S/spin 8 120 & P=$!; sleep 1
one base-120k-spin base 120000
one tokio-120k-spin tokio 120000
one base2-120k-spin base 120000
kill $P; wait $P 2>/dev/null
echo done
