#!/bin/sh
# time.sh N PROJECT NAME...: interleave lh/NAME/bin on core 8 (sibling 9 idle), --singleThreaded;
# per NAME: fastest wall (ms), fastest cycles, fewest instructions (user, P-core). Outputs must match the first.
set -u
n=$1; p=$2; shift 2
out=$(mktemp -d /zfs/trig-cache/lh.XXXXXX)
ev=cpu_core/instructions/u,cpu_core/cycles/u,task-clock
cd ~/Data/Code/trig/misc/projects/$p
first=""
for v in "$@"; do
  b=/zfs/trig-pup/trial/lh/$v/bin
  e=0; taskset -c 8 $b -p tsconfig.trig.json --noEmit --singleThreaded > $out/$v.out 2>&1 || e=$?
  echo $e >> $out/$v.out
  if [ -z "$first" ]; then first=$v; elif ! cmp -s $out/$first.out $out/$v.out; then echo "$p: $v output differs from $first"; fi
done
for i in $(seq 1 $n); do
  for v in "$@"; do
    b=/zfs/trig-pup/trial/lh/$v/bin
    s=$(date +%s%N)
    perf stat -x, -e $ev -o $out/$v.$i.stat taskset -c 8 $b -p tsconfig.trig.json --noEmit --singleThreaded >/dev/null 2>&1
    e=$(date +%s%N); echo $(( (e - s) / 1000 )) > $out/$v.$i.wall
  done
done
for v in "$@"; do
  w=$(cat $out/$v.*.wall | sort -n | head -1)
  c=$(grep -h "/cycles/" $out/$v.*.stat | cut -d, -f1 | sort -n | head -1)
  ins=$(grep -h "/instructions/" $out/$v.*.stat | cut -d, -f1 | sort -n | head -1)
  printf "%-12s %-10s wall %8.1f ms  cycles %7.4fG  instr %7.4fG\n" $p $v $(echo "$w / 1000" | bc -l) $(echo "$c / 1000000000" | bc -l) $(echo "$ins / 1000000000" | bc -l)
done
rm -rf $out
