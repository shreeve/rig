#!/bin/sh
# ab.sh ROUNDS OUT: arms none/ui/ux at 1, 4, 6, 10 checkers, interleaved, order rotated each round.
Q=$(dirname $0); R=$1; OUT=$2; : > $OUT
for r in $(seq 1 $R); do
  for c in 1 4 6 10; do
    case $((r % 3)) in 0) arms="none ui ux";; 1) arms="ui ux none";; 2) arms="ux none ui";; esac
    for a in $arms; do
      line=$(RIG_QOS=$a $Q/pcore $Q/arm $c 2>&1 | grep -E '^wall|^pcore' | tr '\n' ' ')
      echo "r=$r c=$c arm=$a load=$(sysctl -n vm.loadavg | awk '{print $2}') $line" >> $OUT
    done
  done
done
