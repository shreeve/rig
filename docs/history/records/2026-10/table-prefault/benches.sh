#!/bin/sh
# benches.sh build | ROUNDS: bench/tasks and bench/http (rig-fast) of main
# and the probe, built once, then timed pinned to cores 6 and 7, interleaved.
P=/zfs/worktrees/rig/table-prefault
export PATH=$HOME/.local/go/bin:$PATH
if [ "$1" = build ]; then
  for b in tasks http; do for v in main probe; do
    (cd $P/$v && RIG=$P/$v/bin/rig python3 bench/$b/bench-$b --variants rig-fast --build-only --out $P/bench-$b-$v > $P/bench-build-$b-$v.log 2>&1; echo "$b $v $?")
  done; done; exit 0
fi
for r in $(seq 1 $1); do
  for b in tasks http; do
    for v in main probe; do
      echo "== $b $v round $r (load $(cut -d' ' -f1 /proc/loadavg))"; (cd $P/$v && taskset -c 6,7 python3 bench/$b/bench-$b --variants rig-fast --time-only --out $P/bench-$b-$v 2>&1)
    done
  done
done
echo DONE
