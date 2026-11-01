#!/bin/sh
# ecount.sh N CORE OUT VARIANT...: N rounds on one core (an E-core while
# someone times on the P-cores), the variants rotated each round (round r
# starts with variant r mod k), one checker, check mode, on the empty
# project, mitt, ts-pattern and zod3. A VARIANT is a name under v/. One
# line per run: wall (perf duration_time), user cycles and instructions,
# peak RSS, and whether stdout and the exit status equal the first
# variant's first run, byte for byte.
set -u
N=$1 CORE=$2 OUT=$3; shift 3
W=/zfs/worktrees/rig/scan-yield-study
P=/zfs/trig-pup/full/trig/misc/projects
case $CORE in 1[2-9]) EV=cpu_atom ;; *) EV=cpu_core ;; esac
T=$(mktemp -d /zfs/trig-cache/scanyield.XXXXXX)
k=$#
for proj in empty mitt ts-pattern zod3; do
  if [ $proj = empty ]; then cd $W/empty; else cd $P/$proj; fi
  r=1
  while [ $r -le $N ]; do
    while pgrep -f "tools/full-main" > /dev/null; do echo "# $(date +%T) waiting: Trig full suite" >&2; sleep 60; done
    s=$(( (r - 1) % k )); i=0
    for v in "$@" "$@"; do
      i=$((i + 1)); [ $i -le $s ] && continue; [ $i -gt $((s + k)) ] && break
      e=0
      /usr/bin/time -f "%M" -o $T/time perf stat -x, -e duration_time,$EV/cycles/u,$EV/instructions/u -o $T/perf taskset -c $CORE $W/v/$v/bin -p tsconfig.trig.json --noEmit --singleThreaded > $T/out 2>&1 || e=$?
      echo "exit $e" >> $T/out
      [ -e $T/ref.$proj ] || cp $T/out $T/ref.$proj
      same=1; cmp -s $T/ref.$proj $T/out || same=0
      cyc=$(grep /cycles/ $T/perf | cut -d, -f1); ins=$(grep /instructions/ $T/perf | cut -d, -f1); ns=$(grep duration_time $T/perf | cut -d, -f1); rss=$(tail -n 1 $T/time)
      echo "$proj round=$r v=$v ns=$ns cycles=$cyc instructions=$ins rss_kb=$rss exit=$e same=$same load=$(cut -d" " -f1 /proc/loadavg)"
    done
    r=$((r + 1))
  done
done >> $OUT
echo "# done $(date +%T)" >> $OUT
rm -rf $T
