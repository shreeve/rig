#!/bin/sh
# bench.sh build NAME...: build bench tasks/actors/net/http (rig-fast) and
#   json (rig-safe, rig-fast) with af/rig-NAME, each on a release slot.
# bench.sh time ROUNDS NAME...: time them, builds interleaved per round
#   (order reversed on even rounds), pinned to cores 6,7.
export PATH=$HOME/.local/go/bin:$HOME/.local/bin:$PATH
A=/zfs/trig-pup/trial/af
cmd=$1; shift
if [ $cmd = build ]; then
  for n in "$@"; do
    R=$A/rig-$n; mkdir -p $A/bench/$n
    ln -sfn $A/jsondata/simd-json $R/bench/json/check/data/simd-json
    for b in tasks actors net http; do
      RIG_OUT_DIR=$A/bench/$n/o-$b sh /zfs/trig-pup/trial/slot.sh python3 $R/bench/$b/bench-$b --variants rig-fast --out $A/bench/$n/$b --build-only > $A/bench/$n/build-$b.log 2>&1 || echo "build $n $b failed"
    done
    RIG_OUT_DIR=$A/bench/$n/o-json sh /zfs/trig-pup/trial/slot.sh python3 $R/bench/json/bench-json --variants rig-safe,rig-fast --out $A/bench/$n/json --build-only > $A/bench/$n/build-json.log 2>&1 || echo "build $n json failed"
    echo "built benches $n"
  done
  exit 0
fi
rounds=$1; shift
names="$@"; rev=$(for n in $names; do echo $n; done | tac | tr "\n" " ")
for r in $(seq 1 $rounds); do
  if [ $((r % 2)) = 0 ]; then order=$rev; else order=$names; fi
  for b in tasks actors net http json; do
    for n in $order; do
      R=$A/rig-$n
      case $b in
        json) s=$R/bench/json/bench-json; extra="--reps 5 --variants rig-safe,rig-fast";;
        *) s=$R/bench/$b/bench-$b; extra="--reps 3 --variants rig-fast";;
      esac
      echo "== $b $n round $r"
      taskset -c 6,7 python3 $s --out $A/bench/$n/$b --time-only $extra 2>&1
    done
  done
done
