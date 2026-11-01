#!/bin/bash
# timeceil.sh N ARM...: Trig built with each arm's Rig, rotated (each round
# starts one arm later), N rounds, on core 3 with sibling 4 idle: the empty
# project, mitt and zod3 at one checker. Fastest task-clock and cycles,
# median instructions. Outputs and exit codes must agree with the first arm.
set -u
n=$1; shift; arms=("$@"); k=${#arms[@]}
out=$(mktemp -d /zfs/trig-cache/ceil.XXXXXX)
ev=cpu_core/instructions/u,cpu_core/cycles/u,task-clock
bin() { echo /zfs/trig-pup/trial/ab/c-$1/bin; }
echo "start $(date '+%F %T') load $(cut -d' ' -f1-3 /proc/loadavg)"
for s in empty mitt zod3; do
  if [ $s = empty ]; then cd /zfs/trig-cache/fe-proj/empty; else cd $HOME/Data/Code/trig/misc/projects/$s; fi
  ok=1
  for a in "${arms[@]}"; do
    e=0; taskset -c 3 $(bin $a) -p tsconfig.trig.json --noEmit --singleThreaded >$out/$a.out 2>&1 || e=$?
    echo "exit $e" >>$out/$a.out
    cmp -s $out/${arms[0]}.out $out/$a.out || { echo "$s: $a differs from ${arms[0]}; not timed"; ok=0; }
  done
  [ $ok = 1 ] || continue
  for i in $(seq 0 $((n - 1))); do
    for j in $(seq 0 $((k - 1))); do
      a=${arms[$(( (i + j) % k ))]}
      perf stat -x, -e $ev -o $out/$a.$i.stat taskset -c 3 $(bin $a) -p tsconfig.trig.json --noEmit --singleThreaded >/dev/null 2>&1 || true
    done
  done
  for a in "${arms[@]}"; do
    t=$(grep -h ',task-clock,' $out/$a.*.stat | cut -d, -f1 | sort -n | head -1)
    tm=$(grep -h ',task-clock,' $out/$a.*.stat | cut -d, -f1 | sort -n | sed -n "$(( (n + 1) / 2 ))p")
    c=$(grep -h '/cycles/' $out/$a.*.stat | cut -d, -f1 | sort -n | head -1)
    ins=$(grep -h '/instructions/' $out/$a.*.stat | cut -d, -f1 | sort -n | sed -n "$(( (n + 1) / 2 ))p")
    printf '%-6s %-6s fastest %8.2f ms  median %8.2f ms  cycles %9.3fM  instr %9.3fM\n' $s $a $t $tm "$(echo "$c / 1000000" | bc -l)" "$(echo "$ins / 1000000" | bc -l)"
  done
  rm -f $out/*
done
rm -rf $out
echo "end $(date '+%F %T')"
