#!/bin/sh
# trigbench.sh LABEL ROUNDS PROJECT CHECKERS MODE NAME...: run each Trig
# build packs/NAME/bin on PROJECT, interleaved, the order rotated each
# round. CHECKERS 1 is `--singleThreaded` on core 8 (sibling 9 idle);
# 4 is `--checkers 4` on cores 6-9. MODE warm runs it alone; cold runs it
# beside `pollute` on E-core 12, which streams through 256 MiB, evicting
# the shared cache. One line a run: perf's user cycles and instructions,
# elapsed seconds, peak RSS (KB), whether stdout matches the first build's.
set -u
W=/zfs/worktrees/rig/map-inline
label=$1 rounds=$2 proj=$3 ck=$4 mode=$5
shift 5
names="$*"
dir=$W/trig/misc/projects/$proj
if [ "$ck" = 1 ]; then cpus=8 flags="--singleThreaded"; else cpus=6-9 flags="--checkers $ck"; fi
pid=
if [ "$mode" = cold ]; then taskset -c 12 $W/pollute & pid=$!; sleep 0.5; fi
tmp=$(mktemp -d)
n=$(echo $names | wc -w)
r=1
while [ $r -le $rounds ]; do
  set -- $names
  k=$(( (r - 1) % n )); while [ $k -gt 0 ]; do x=$1; shift; set -- "$@" $x; k=$((k - 1)); done
  for b in "$@"; do
    (cd $dir && /usr/bin/time -f "%M %e" -o $tmp/time perf stat -x, -e cpu_core/cycles/u,cpu_core/instructions/u,duration_time -o $tmp/perf taskset -c $cpus $W/packs/$b/bin -p tsconfig.trig.json --noEmit $flags > $tmp/out.$b 2>&1)
    cyc=$(grep cycles $tmp/perf | cut -d, -f1)
    ins=$(grep instructions $tmp/perf | cut -d, -f1)
    dur=$(grep duration_time $tmp/perf | cut -d, -f1); set -- $(tail -n 1 $tmp/time)
    first=$(echo $names | cut -d' ' -f1)
    same=1; [ -f $tmp/out.$first ] && ! cmp -s $tmp/out.$first $tmp/out.$b && same=0
    echo "$label round=$r build=$b cycles=$cyc instructions=$ins secs=$(echo $dur | awk "{printf \"%.4f\", \$1/1e9}") rss_kb=$1 same=$same"
  done
  r=$((r + 1))
done
[ -n "$pid" ] && kill $pid
rm -rf $tmp
