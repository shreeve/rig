#!/bin/sh
# On pup: time.sh N TAG V...: N rounds, the variants V interleaved in each
# (v/V/bin, or "tsrs" for shipped tsrs in Go mode on one thread), on core 8
# with its sibling 9 idle, ts-pattern then zod3, one checker. One line per
# run: wall (perf duration_time), user cycles and instructions, peak RSS,
# and whether the output is byte-identical to the first variant's.
set -u
N=$1 TAG=$2; shift 2
W=/zfs/worktrees/rig/trig-zig-ceiling
P=/zfs/trig-pup/full/trig/misc/projects
TSRS=/zfs/trig-pup/tsrs-shipped/package/tsrs
O=$W/time/$TAG; mkdir -p $O
first=$1
cmd_of() {
  case $1 in
    tsrs) echo "env RAYON_NUM_THREADS=1 $TSRS -p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers" ;;
    *) echo "$W/v/$1/bin -p tsconfig.trig.json --noEmit --singleThreaded" ;;
  esac
}
quiet() {
  while pgrep -f "tools/full-main" > /dev/null; do echo "# $(date +%T) waiting: Trig full suite running" >&2; sleep 60; done
  while [ -n "$(ps -eo psr,pcpu,comm --no-headers | awk "\$1==8 && \$2>20")" ]; do echo "# $(date +%T) waiting: core 8 busy" >&2; sleep 30; done
}
for proj in ts-pattern zod3; do
  cd $P/$proj
  r=1
  while [ $r -le $N ]; do
    quiet
    for v in "$@"; do
      e=0
      /usr/bin/time -f "%M %e" -o $O/time perf stat -x, -e duration_time,cpu_core/cycles/u,cpu_core/instructions/u -o $O/perf taskset -c 8 $(cmd_of $v) > $O/out.$proj.$v 2>&1 || e=$?
      cyc=$(grep cycles $O/perf | cut -d, -f1); ins=$(grep instructions $O/perf | cut -d, -f1); ns=$(grep duration_time $O/perf | cut -d, -f1); rss=$(tail -n 1 $O/time | cut -d" " -f1)
      same=1; case $v in tsrs) ;; *) cmp -s $O/out.$proj.$first $O/out.$proj.$v || same=0 ;; esac
      echo "$proj round=$r v=$v ns=$ns cycles=$cyc instructions=$ins rss_kb=$rss exit=$e same=$same load=$(cut -d" " -f1 /proc/loadavg)"
    done
    r=$((r + 1))
  done
done >> $O/times.txt
echo "# done $(date +%T)" >> $O/times.txt
