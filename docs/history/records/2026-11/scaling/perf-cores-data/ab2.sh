#!/bin/sh
# ab2.sh ROUNDS OUT SPINNERS: as ab.sh at 4 and 6 checkers, with SPINNERS busy loops at nice 0 running.
Q=$(dirname $0); R=$1; OUT=$2; S=$3; : > $OUT
pids=""
for i in $(seq 1 $S); do yes > /dev/null & pids="$pids $!"; done
sleep 1
for r in $(seq 1 $R); do
  for c in 4 6; do
    case $((r % 3)) in 0) arms="none ui ux";; 1) arms="ui ux none";; 2) arms="ux none ui";; esac
    for a in $arms; do
      line=$(RIG_QOS=$a $Q/pcore $Q/arm $c 2>&1 | grep -E '^wall|^pcore' | tr '\n' ' ')
      echo "r=$r c=$c arm=$a load=$(sysctl -n vm.loadavg | awk '{print $2}') $line" >> $OUT
    done
  done
done
kill $pids
