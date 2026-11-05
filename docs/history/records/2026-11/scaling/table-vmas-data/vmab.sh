#!/bin/bash
# vmab.sh OUT ROUNDS: the exit of each memory shape (vmabench), under exitwatch on core 16.
OUT=$1; N=$2; : > $OUT
cd /zfs/rig-work/scaling/eh
for r in $(seq 1 $N); do
  for shape in "0 4 1" "0 4 1300" "45000 4 1" "45000 4 1300" "45000 40 1" "45000 40 1300" "45000 2048 1"; do
    echo "shape=$(echo $shape | tr " " ,) $(taskset -c 16 ./exitwatch ./vmabench $shape 2>&1 | grep exitwatch)" >> $OUT
  done
done
