#!/bin/sh
# bench.sh build NAME...: build bench/hash and bench/json (rig-safe, rig-fast)
#   with lg/rig-NAME, each on a release slot.
# bench.sh time ROUNDS NAME...: time them on core 8, builds interleaved per
#   round (order reversed on even rounds).
export PATH=$HOME/.local/bin:$PATH
L=/zfs/trig-pup/trial/lg
cmd=$1; shift
if [ $cmd = build ]; then
  for n in "$@"; do
    R=$L/rig-$n; mkdir -p $L/bench/$n
    mkdir -p $R/bench/json/check/data; ln -sfn /zfs/trig-pup/trial/af/jsondata/simd-json $R/bench/json/check/data/simd-json
    RIG_OUT_DIR=$L/bench/$n/o-hash sh /zfs/trig-pup/trial/slot.sh python3 $R/bench/hash/bench-hash --variants rig-safe,rig-fast --out $L/bench/$n/hash --build-only > $L/bench/$n/build-hash.log 2>&1 || echo "build $n hash failed"
    RIG_OUT_DIR=$L/bench/$n/o-json sh /zfs/trig-pup/trial/slot.sh python3 $R/bench/json/bench-json --variants rig-safe,rig-fast --out $L/bench/$n/json --build-only > $L/bench/$n/build-json.log 2>&1 || echo "build $n json failed"
    echo "built benches $n"
  done
  exit 0
fi
rounds=$1; shift
names="$@"; rev=$(for n in $names; do echo $n; done | tac | tr "\n" " ")
for r in $(seq 1 $rounds); do
  if [ $((r % 2)) = 0 ]; then order=$rev; else order=$names; fi
  for b in hash json; do
    for n in $order; do
      R=$L/rig-$n
      case $b in
        json) s=$R/bench/json/bench-json; extra="--reps 5 --variants rig-safe,rig-fast";;
        hash) s=$R/bench/hash/bench-hash; extra="--reps 3 --variants rig-safe,rig-fast";;
      esac
      echo "== $b $n round $r"
      taskset -c 8 python3 $s --out $L/bench/$n/$b --time-only $extra 2>&1
    done
  done
done
