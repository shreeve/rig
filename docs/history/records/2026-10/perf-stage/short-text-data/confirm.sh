#!/bin/bash
ev=cpu_core/instructions/u,cpu_core/cycles/u,task-clock
D=/zfs/trig-cache/c38run
m() { echo "$1 / 1000000" | bc -l; }
for s in empty mitt; do
  if [ $s = empty ]; then cd /zfs/trig-cache/fe-proj/empty; else cd ~/Data/Code/trig/misc/projects/mitt; fi
  for i in $(seq 0 29); do
    if [ $((i%2)) = 0 ]; then ord="base c38"; else ord="c38 base"; fi
    for a in $ord; do perf stat -x, -e $ev -o $D/$s.$a.$i taskset -c 3 /zfs/trig-pup/trial/ab/c-$a/bin -p tsconfig.trig.json --noEmit --singleThreaded >/dev/null 2>&1; done
  done
  for a in base c38; do
    t=$(grep -h task-clock $D/$s.$a.* | cut -d, -f1 | sort -n); c=$(grep -h /cycles/ $D/$s.$a.* | cut -d, -f1 | sort -n); n=$(grep -h /instructions/ $D/$s.$a.* | cut -d, -f1 | sort -n)
    printf "%-6s %-5s time fastest %.2f med %.2f ms  cycles fastest %.3fM med %.3fM  instr min %.3fM med %.3fM max %.3fM\n" $s $a $(echo "$t" | head -1) $(echo "$t" | sed -n 15p) $(m $(echo "$c" | head -1)) $(m $(echo "$c" | sed -n 15p)) $(m $(echo "$n" | head -1)) $(m $(echo "$n" | sed -n 15p)) $(m $(echo "$n" | tail -1))
  done
done
