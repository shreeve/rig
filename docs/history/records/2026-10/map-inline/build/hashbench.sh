#!/bin/sh
# hashbench.sh ROUNDS BIN...: run each bench/hash binary ROUNDS times,
W=/zfs/worktrees/rig/map-inline
# interleaved, the order rotated each round, on core 8 (sibling 9 idle);
# one line a row: the binary, the round, and its `KEYS OP NS CHECK`.
set -u
rounds=$1; shift
bins="$*"
n=$(echo $bins | wc -w)
r=1
while [ $r -le $rounds ]; do
  QLOG=${QLOG:-$W/res/quiet.log} sh $W/quiet.sh
  set -- $bins
  k=$(( (r - 1) % n )); while [ $k -gt 0 ]; do x=$1; shift; set -- "$@" $x; k=$((k - 1)); done
  for b in "$@"; do
    taskset -c 8 $b 2>&1 | sed "s|^|$(echo $b | sed "s,hash/,,; s,/,-,g") $r |"
  done
  r=$((r + 1))
done
