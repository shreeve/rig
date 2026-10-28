#!/bin/sh
# On pup: N rounds, interleaved, core 8 (sibling 9 idle), one checker:
# Trig 403a823 built --release by Rig main (099c1bff3) and by each variant.
# One line per run: wall, cycles, instructions, peak RSS.
set -u
N=${1:-20}; VS=${VS:-"base nh"}
O=/zfs/worktrees/rig/mwk; P=/zfs/trig-pup/full/trig/misc/projects
T=$O/time; mkdir -p $T
quiet() {
  while pgrep -f 'tools/full-main' > /dev/null; do echo "# $(date +%T) waiting: Trig's full suite is running" >&2; sleep 60; done
}
for proj in ts-pattern zod3; do
  cd $P/$proj
  r=1
  while [ $r -le $N ]; do
    quiet
    for v in $VS; do
      e=0
      /usr/bin/time -f "%M %e" -o $T/time perf stat -x, -e duration_time,cpu_core/cycles/u,cpu_core/instructions/u -o $T/perf taskset -c 8 $O/packs/$v/bin -p tsconfig.trig.json --noEmit --singleThreaded > $T/out.$proj.$v 2>&1 || e=$?
      cyc=$(grep cycles $T/perf | cut -d, -f1); ins=$(grep instructions $T/perf | cut -d, -f1); ns=$(grep duration_time $T/perf | cut -d, -f1); set -- $(tail -n 1 $T/time)
      same=1; first=${VS%% *}; cmp -s $T/out.$proj.$first $T/out.$proj.$v || same=0
      echo "$proj round=$r v=$v ns=$ns cycles=$cyc instructions=$ins rss_kb=$1 exit=$e same=$same load=$(cut -d' ' -f1 /proc/loadavg)"
    done
    r=$((r + 1))
  done
done
echo "# done $(date +%T)"
