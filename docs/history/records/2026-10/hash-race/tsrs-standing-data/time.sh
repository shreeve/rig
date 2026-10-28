#!/bin/sh
# On pup: N rounds, interleaved, core 8 (sibling 9 idle), one checker.
# Trig 403a823 built by Rig main (PGO and plain), by #735 and before it
# (plain); tsrs shipped (PGO, LTO, BOLT) and its source build, Go mode, one
# thread. One line per run: wall, cycles, instructions, peak RSS, minor faults.
set -u
N=${1:-20}
W=/zfs/worktrees/rig/tsrs-standing
P=/zfs/trig-pup/full/trig/misc/projects
. $W/cmds.sh
O=$W/time; mkdir -p $O
quiet() {
  while pgrep -f 'tools/full-main' > /dev/null; do echo "# $(date +%T) waiting: Trig's full suite is running" >&2; sleep 60; done
}
for proj in ts-pattern zod3; do
  cd $P/$proj
  r=1
  while [ $r -le $N ]; do
    quiet
    for v in $V; do
      e=0
      /usr/bin/time -f "%M %e %R" -o $O/time perf stat -x, -e duration_time,cpu_core/cycles/u,cpu_core/instructions/u -o $O/perf taskset -c 8 $(cmd_of $v) > $O/out.$proj.$v 2>&1 || e=$?
      cyc=$(grep cycles $O/perf | cut -d, -f1); ins=$(grep instructions $O/perf | cut -d, -f1); ns=$(grep duration_time $O/perf | cut -d, -f1); set -- $(tail -n 1 $O/time)
      same=1; case $v in tsrs*) ;; *) cmp -s $O/out.$proj.main-rel $O/out.$proj.$v || same=0 ;; esac
      echo "$proj round=$r v=$v ns=$ns secs=$2 cycles=$cyc instructions=$ins rss_kb=$1 minflt=$3 exit=$e same=$same load=$(cut -d' ' -f1 /proc/loadavg)"
    done
    r=$((r + 1))
  done
done
echo "# done $(date +%T)"
