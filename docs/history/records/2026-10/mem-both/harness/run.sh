#!/bin/bash
# run.sh ROUNDS ARM...: interleaved rounds, the first arm rotated each round.
# Each arm in a round: kv (22 workers, unpinned server; hold then load on
# cores 6-11,20,21; max VmRSS of 25 samples 0.1 s apart during the load)
# at 64 KiB (50 1, 100 keys), 32 B (50 1; 1000 1) and P=16 (50 16); then
# xmalloc-test -w 16 -t 5 -s 64 and sh8bench 32 under the arm's shim
# (cores 0-11,20,21), time and peak RSS by /usr/bin/time.
# Lines: ROUND ARM TEST rss_kb value (req/s, rtime, or seconds).
W=/zfs/worktrees/rig/mem-both
MB=/zfs/worktrees/rig-rust-ports/mbench/mimalloc-bench/out/bench
CLI="taskset -c 6-11,20,21"
ulimit -n 20000
rounds=$1; shift; arms=("$@"); n=${#arms[@]}
port=$((49000 + RANDOM % 5000))
rss() { awk '/VmRSS/{print $2}' /proc/$1/status 2>/dev/null; }
kv() { # ROUND ARM NAME N P [KEYS VLEN]
  r=$1 arm=$2 name=$3; shift 3
  for try in 1 2 3 4; do
    port=$((port+1 + RANDOM % 50))
    $W/kv-$arm $port >/dev/null 2>&1 & sp=$!; sleep 0.5
    kill -0 $sp 2>/dev/null && break
  done
  $CLI $W/hold 127.0.0.1:$port $1 3 >/dev/null 2>&1; sleep 0.3
  $CLI $W/load 127.0.0.1:$port $1 $2 3 ${3:-} ${4:-} > $W/load.out 2>/dev/null & lp=$!
  mx=0; for i in $(seq 25); do sleep 0.1; x=$(rss $sp); [ -n "$x" ] && [ $x -gt $mx ] && mx=$x; done
  wait $lp; kill $sp; wait $sp 2>/dev/null
  echo "$r $arm $name $mx $(cut -d' ' -f3 $W/load.out | cut -d= -f2)"
}
mb() { # ROUND ARM
  r=$1 arm=$2 lib=$W/shim/$2/librigalloc.so
  cd $MB
  LD_PRELOAD=$lib taskset -c 0-11,20,21 /usr/bin/time -f "%e %M" -o $W/t.out ./xmalloc-test -w 16 -t 5 -s 64 > $W/x.out 2>&1
  echo "$r $arm xmalloc $(cut -d' ' -f2 $W/t.out) $(grep -o 'rtime: [0-9.]*' $W/x.out | tail -1 | cut -d' ' -f2)"
  LD_PRELOAD=$lib taskset -c 0-11,20,21 /usr/bin/time -f "%e %M" -o $W/t.out ./sh8bench 32 > $W/s.out 2>&1
  echo "$r $arm sh8bench $(cut -d' ' -f2 $W/t.out) $(cut -d' ' -f1 $W/t.out)"
  cd $W
}
# ONLY64=1 runs only kv64k, xmalloc-test and sh8bench. FIRST=R starts at round R; STOP=HHMM starts no round after that time.
for r in $(seq ${FIRST:-1} $rounds); do
  [ -n "${STOP:-}" ] && [ $(date +%H%M) -ge $STOP ] && { echo "stopped before round $r"; exit 0; }
  for k in $(seq 0 $((n-1))); do
    arm=${arms[$(( (k + r - 1) % n ))]}
    kv $r $arm kv64k 50 1 100 65536
    if [ -z "${ONLY64:-}" ]; then
      kv $r $arm kv32 50 1
      kv $r $arm kv32c1000 1000 1
      kv $r $arm kvP16 50 16
    fi
    mb $r $arm
  done
done
