#!/bin/sh
# On pup: time.sh N TAG CORE SIB V...: N rounds, the arms V (bin/V)
# interleaved in each round and their order rotated each round, on P-core
# CORE with its sibling SIB idle, ts-pattern then zod3, one checker
# (--noEmit --singleThreaded). One line per run: wall (perf's
# duration_time), user cycles, total cycles (user and kernel), user
# instructions, peak RSS, exit status; and a DIFF line for any output not
# byte-identical to the first arm's in that round. A round waits while
# Trig's full suite runs or another process uses CORE or SIB.
set -u
N=$1 TAG=$2 CORE=$3 SIB=$4; shift 4
P=/zfs/worktrees/rig/ids-ceiling
O=$P/time/$TAG; mkdir -p $O
first=$1
quiet() {
  while pgrep -f "tools/full-main" > /dev/null; do echo "# $(date +%T) waiting: Trig full suite running" >&2; sleep 60; done
  while [ -n "$(ps -eo psr,pcpu,comm --no-headers | awk -v a=$CORE -v b=$SIB '($1==a || $1==b) && $2>20')" ]; do echo "# $(date +%T) waiting: core $CORE or $SIB busy" >&2; sleep 30; done
}
echo "# start $(date '+%F %T') load=$(cut -d' ' -f1-3 /proc/loadavg) core=$CORE sib=$SIB arms=$*" >> $O/times.txt
for proj in ts-pattern zod3; do
  cd $P/projects/$proj
  r=1
  while [ $r -le $N ]; do
    quiet
    set -- $(echo "$@" | tr ' ' '\n' | awk -v r=$r 'BEGIN{n=0}{a[n++]=$0}END{for(i=0;i<n;i++)print a[(i+r)%n]}')
    for v in "$@"; do
      e=0
      /usr/bin/time -f "%M %e" -o $O/time perf stat -x, -e duration_time,cpu_core/cycles/u,cpu_core/cycles/,cpu_core/instructions/u -o $O/perf taskset -c $CORE $P/bin/$v -p tsconfig.trig.json --noEmit --singleThreaded > $O/out.$proj.$v 2>&1 || e=$?
      cyc=$(awk -F, '$3=="cpu_core/cycles/u"{print $1}' $O/perf); tcyc=$(awk -F, '$3=="cpu_core/cycles/"{print $1}' $O/perf); ins=$(awk -F, '$3=="cpu_core/instructions/u"{print $1}' $O/perf); ns=$(awk -F, '$3=="duration_time"{print $1}' $O/perf); rss=$(tail -n 1 $O/time | cut -d" " -f1)
      echo "$proj round=$r v=$v ns=$ns cycles=$cyc total_cycles=$tcyc instructions=$ins rss_kb=$rss exit=$e load=$(cut -d" " -f1 /proc/loadavg)"
    done
    for v in "$@"; do cmp -s $O/out.$proj.$first $O/out.$proj.$v || echo "# DIFF $proj round=$r v=$v"; done
    r=$((r + 1))
  done
done >> $O/times.txt
echo "# done $(date '+%F %T')" >> $O/times.txt
