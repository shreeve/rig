#!/bin/sh
# trigtime.sh N: N interleaved rounds (arm order rotated each round) of
# Trig's PGO build by main and by the PR on ts-pattern then zod3, one
# checker, on P-core 1 with its sibling 2 idle; one line a run.
set -u
N=${1:-20}
W=/zfs/worktrees/rig/rehash-x86
P=$W/trig/misc/projects
O=$W/time; mkdir -p $O
ARGS="-p tsconfig.trig.json --noEmit --singleThreaded"
V="main pr"
bin_of() { echo "$W/packs/$1-pgo/bin"; }
echo "# start $(date +%T) N=$N load $(cut -d' ' -f1-3 /proc/loadavg)"
for proj in ts-pattern zod3; do
  cd $P/$proj
  [ -s $O/ref.$proj ] || taskset -c 1 $(bin_of main) $ARGS > $O/ref.$proj 2>&1
  r=1
  while [ $r -le $N ]; do
    set -- $V; [ $((r % 2)) -eq 0 ] && set -- pr main
    for v in "$@"; do
      e=0
      /usr/bin/time -f "%M" -o $O/time perf stat -x, -e duration_time,cpu_core/cycles/u,cpu_core/cycles/k,cpu_core/instructions/u -o $O/perf taskset -c 1 $(bin_of $v) $ARGS > $O/out.$proj.$v 2>&1 || e=$?
      f=$(awk -F, '/^[0-9]/ { k=$3; sub("cpu_core/", "", k); sub("/$", "", k); printf "%s=%s ", k, $1 }' $O/perf)
      same=1; cmp -s $O/ref.$proj $O/out.$proj.$v || same=0
      echo "$proj round=$r v=$v ${f}rss_kb=$(tail -n 1 $O/time) exit=$e same=$same load=$(cut -d' ' -f1 /proc/loadavg)"
    done
    r=$((r + 1))
  done
done
echo "# done $(date +%T)"
