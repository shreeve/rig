#!/bin/sh
# ab.sh N PROJECT NAME...: interleave packs/NAME/bin on core 8 (sibling 9 idle),
# order reversed every other round; per build the fastest task-clock and wall,
# fewest user cycles and instructions of N. Outputs must match first.
set -u
n=$1; p=$2; shift 2
W=/zfs/worktrees/rig/bounds-enum
out=$(mktemp -d /zfs/trig-cache/be-ab.XXXXXX)
ev=cpu_core/instructions/u,cpu_core/cycles/u,task-clock,duration_time
cd "$W/trig/misc/projects/$p"
first=
for v in "$@"; do
  e=0; taskset -c 8 $W/packs/$v/bin -p tsconfig.trig.json --noEmit --singleThreaded > $out/$v.out 2>&1 || e=$?
  echo $e >> $out/$v.out
  if [ -z "$first" ]; then first=$v; elif ! cmp -s $out/$first.out $out/$v.out; then echo "$p: $first and $v differ; not timed"; exit 1; fi
done
echo "$p: outputs identical ($(md5sum < $out/$first.out | cut -c1-12))"
order="$*"; rev=$(for v in "$@"; do echo $v; done | tac | tr "\n" " ")
for i in $(seq 1 $n); do
  if [ $((i % 2)) -eq 0 ]; then o=$rev; else o=$order; fi
  for v in $o; do
    perf stat -x, -e $ev -o $out/$v.$i.stat taskset -c 8 $W/packs/$v/bin -p tsconfig.trig.json --noEmit --singleThreaded >/dev/null 2>&1 || true
  done
done
for v in "$@"; do
  t=$(grep -h ",task-clock," $out/$v.*.stat | cut -d, -f1 | sort -n | head -1)
  w=$(grep -h ",duration_time," $out/$v.*.stat | cut -d, -f1 | sort -n | head -1)
  c=$(grep -h "/cycles/u" $out/$v.*.stat | cut -d, -f1 | sort -n | head -1)
  ins=$(grep -h "/instructions/" $out/$v.*.stat | cut -d, -f1 | sort -n | head -1)
  printf "%-12s %-10s task-clock %8.1f ms  wall %8.1f ms  cycles %9.2fM  instr %10.2fM\n" "$p" $v "$t" "$(echo "$w / 1000000" | bc -l)" "$(echo "$c / 1000000" | bc -l)" "$(echo "$ins / 1000000" | bc -l)"
done
rm -rf $out
