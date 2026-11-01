#!/bin/sh
# ecore.sh N PROJECT...: on pup, each arm in /tmp/lazy-table/bin once per round, in an order
# shuffled by the round, on E-core 13 under `taskset -c 13 perf stat --no-scale` (perf pinned
# with the program), one checker. Waits out Trig's full suite and its cron hours. Lines:
# PROJECT round=R v=ARM <perf fields> rss_kb= exit= same=
set -u
N=$1; shift
D=/tmp/lazy-table; B=$D/bin; O=$D/out; mkdir -p $O
P=/zfs/trig-pup/full/trig/misc/projects
V="mainbase mainbase2 mainlazy2 pbbase pbdefer2"
EV=duration_time,cpu_atom/instructions/u,cpu_atom/instructions/k,cpu_atom/cycles/u,cpu_atom/cycles/k,page-faults
quiet() {
  while pgrep -f "tools/full-main" > /dev/null || [ $(( $(date +%-H) % 4 )) -eq 0 -a $(date +%-M) -lt 10 ]; do echo "# $(date +%T) waiting: Trig's suite"; sleep 60; done
}
run() {
  e=0
  /usr/bin/time -f "%M" -o $O/time taskset -c 13 perf stat --no-scale -x, -e $EV -o $O/perf $B/$2 -p tsconfig.trig.json --noEmit --singleThreaded > $O/out.$1.$2 2>&1 || e=$?
  f=$(awk -F, '/^[0-9]/ { k=$3; printf "%s=%s ", k, $1 }' $O/perf)
  echo "${f}rss_kb=$(tail -n 1 $O/time) exit=$e"
}
order() { echo $V | tr ' ' '\n' | awk -v seed=$1 'BEGIN { srand(seed) } { print rand(), $0 }' | sort -n | cut -d' ' -f2 | tr '\n' ' '; }
echo "# start $(date +%T) N=$N"
for proj in "$@"; do
  if [ $proj = empty ]; then cd $D/empty; else cd $P/$proj; fi
  quiet
  for v in $V; do run $proj $v > /dev/null; cp $O/out.$proj.$v $O/ref.$proj.$v; done
  r=1
  while [ $r -le $N ]; do
    quiet
    for v in $(order $r); do
      line=$(run $proj $v)
      same=1; cmp -s $O/ref.$proj.mainbase $O/out.$proj.$v || same=0
      echo "$proj round=$r v=$v $line same=$same"
    done
    r=$((r + 1))
  done
done
echo "# done $(date +%T)"
