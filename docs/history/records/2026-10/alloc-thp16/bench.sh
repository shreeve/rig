#!/bin/sh
# bench.sh build NAME...: build bench tasks/actors/net/http (rig-fast)
#   with rig-NAME, on cores 0,1.
# bench.sh time ROUNDS NAME...: time them, builds interleaved per round
#   (order reversed on even rounds), pinned to cores 6,7.
export PATH=$HOME/.local/go/bin:$HOME/.local/bin:$PATH XDG_CACHE_HOME=/zfs/rig/xdg-cache
A=/zfs/worktrees/rig/alloc-thp16
cmd=$1; shift
if [ $cmd = build ]; then
  for n in "$@"; do
    R=$A/rig-$n; mkdir -p $A/bench/$n
    for b in tasks actors net http; do
      RIG=$R/bin/rig RIG_OUT_DIR=$A/bench/$n/o-$b taskset -c 0,1 python3 $R/bench/$b/bench-$b --variants rig-fast --out $A/bench/$n/$b --build-only > $A/bench/$n/build-$b.log 2>&1 || echo "build $n $b failed"
    done
    echo "built benches $n"
  done
  exit 0
fi
rounds=$1; shift
names="$@"; rev=$(for n in $names; do echo $n; done | tac | tr "\n" " ")
for r in $(seq 1 $rounds); do
  if [ $((r % 2)) = 0 ]; then order=$rev; else order=$names; fi
  for b in tasks actors net http; do
    for n in $order; do
      R=$A/rig-$n
      echo "== $b $n round $r"
      RIG=$R/bin/rig taskset -c 6,7 python3 $R/bench/$b/bench-$b --out $A/bench/$n/$b --time-only --reps 3 --variants rig-fast 2>&1
    done
  done
done
