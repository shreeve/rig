#!/bin/bash
# batch.sh ROUNDS: ROUNDS rounds of the replay over Trig's streams on
# E-core 18, the arms' order rotating, with main's b1r Trig run at c1 on
# each project every other round (5 runs a project in 10 rounds). Run
# under the E-core lock with taskset -c 18.
set -u
cd /zfs/trig-pup/map-replay
R=${1:-10}
B=/zfs/trig-pup/runs/b1r/.zig-cache/trig-tests/packs/trig-pgo/bin-bolt
O=traces/batch; mkdir -p $O; : > $O/walls.txt
declare -A DIR=([Compiler-Unions]=/zfs/trig-pup/corpus/typescript-benchmarking/cases/solutions/Compiler-Unions
  [typeorm]=/zfs/trig-pup/corpus/typeorm/packages/typeorm [webpack]=/zfs/trig-pup/corpus/webpack
  [supabase-studio]=/zfs/trig-pup/corpus/supabase-studio/apps/studio)
TR=$(sed 's#^#traces/trig/#' traces/trig-list.txt)
for r in $(seq 1 $R); do
  if [ $((r % 2)) = 1 ]; then
    for p in Compiler-Unions typeorm webpack supabase-studio; do
      ( cd -P "${DIR[$p]}" || exit 1; cfg=tsconfig.json; [ -f tsconfig.trig.json ] && cfg=tsconfig.trig.json
        t0=$EPOCHREALTIME; env -u TRIG_PREBUILT_LIBS taskset -c 18 $B --singleThreaded -p $cfg --noEmit > /dev/null 2>&1; rc=$?; t1=$EPOCHREALTIME
        echo "$p round=$r cfg=$cfg wall_ms=$(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.2f",(b-a)*1000}') rc=$rc" ) >> $O/walls.txt
    done
  fi
  python3 bench/hash/replay/replay time --out out --rounds 1 --rotate $r --aa hb-fx --root traces/trig --json $O/round$r.json $TR > $O/round$r.txt 2>&1 \
    || { echo "round $r failed"; tail -3 $O/round$r.txt; exit 1; }
  echo "round $r done $(date +%T)"
done
