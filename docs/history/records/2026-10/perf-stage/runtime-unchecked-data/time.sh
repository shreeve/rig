#!/bin/sh
# On pup (runtime-unchecked; check-bisect's, with the machine's state
# logged at the start and end): time.sh N TAG V...: N rounds, the variants V interleaved in each
# (v/V/bin), on core 6 with its sibling 7 idle, ts-pattern then zod3, one
# checker. One line per run: wall (perf duration_time), user and total
# (user + kernel) cycles, user instructions, peak RSS, and whether the output is byte-identical to the
# first variant's. The variants' order rotates each round.
set -u
N=$1 TAG=$2; shift 2
W=/zfs/worktrees/rig/runtime-unchecked
P=/zfs/worktrees/rig/check-bisect/projects
O=$W/time/$TAG; mkdir -p $O
first=$1
quiet() {
  while pgrep -f "tools/full-main" > /dev/null; do echo "# $(date +%T) waiting: Trig full suite running" >&2; sleep 60; done
  while [ -n "$(ps -eo psr,pcpu,comm --no-headers | awk '($1==6 || $1==7) && $2>20')" ]; do echo "# $(date +%T) waiting: core 6 or 7 busy" >&2; sleep 30; done
}
state() { echo "# $1 $(date +%T) load=$(cut -d" " -f1 /proc/loadavg) free2M+=$(awk '$4=="Normal"{print $14+$15}' /proc/buddyinfo)" >> $O/times.txt; }
state start
for proj in ts-pattern zod3; do
  cd $P/$proj
  r=1
  while [ $r -le $N ]; do
    quiet
    # rotate the order by the round
    set -- $(echo "$@" | tr ' ' '\n' | awk -v r=$r 'BEGIN{n=0}{a[n++]=$0}END{for(i=0;i<n;i++)print a[(i+r)%n]}')
    for v in "$@"; do
      e=0
      /usr/bin/time -f "%M %e" -o $O/time perf stat -x, -e duration_time,cpu_core/cycles/u,cpu_core/cycles/,cpu_core/instructions/u -o $O/perf taskset -c 6 $W/v/$v/bin -p tsconfig.trig.json --noEmit --singleThreaded > $O/out.$proj.$v 2>&1 || e=$?
      cyc=$(awk -F, '$3=="cpu_core/cycles/u"{print $1}' $O/perf); tcyc=$(awk -F, '$3=="cpu_core/cycles/"{print $1}' $O/perf); ins=$(awk -F, '$3=="cpu_core/instructions/u"{print $1}' $O/perf); ns=$(awk -F, '$3=="duration_time"{print $1}' $O/perf); rss=$(tail -n 1 $O/time | cut -d" " -f1)
      echo "$proj round=$r v=$v ns=$ns cycles=$cyc total_cycles=$tcyc instructions=$ins rss_kb=$rss exit=$e load=$(cut -d" " -f1 /proc/loadavg)"
    done
    for v in "$@"; do cmp -s $O/out.$proj.$first $O/out.$proj.$v || echo "# DIFF $proj round=$r v=$v"; done
    r=$((r + 1))
  done
done >> $O/times.txt
state done
