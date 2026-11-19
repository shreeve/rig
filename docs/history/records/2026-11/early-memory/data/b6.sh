#!/bin/bash
# b6.sh: arms for the early-worker memory board (mem-back), on E-cores 12-19, only while no slot is open.
# cur = main 586e3939a, new = mem-back, aa = a copy of cur, pre = main before #1158 (eval1158's 2dc9a46f5 arms).
set -eu
D=/zfs/trig-pup/psum-gap/mem/b6; mkdir -p $D
E="taskset -c 12-19"; EV=/zfs/trig-pup/eval1158
F=/zfs/trig-pup/standings-1118/order/src/fork-order/fork.rig
free_slot() { for i in $(seq 360); do /zfs/trig-pup/bin/pup-slot state | grep -q "slot=none" && return 0; sleep 10; done; echo "no free slot"; exit 1; }
for pair in cur:586e3939a new:$1; do
  a=${pair%%:*}; S=/zfs/trig-pup/rig-${pair#*:}
  for p in fork:$F few:$EV/fewtask.rig tasks:$S/bench/tasks/tasks.rig; do
    free_slot
    RIG_OUT_DIR=$D/pkg-${p%%:*}-$a $E $S/bin/rig build --release -o $D/${p%%:*}-$a ${p#*:}
  done
done
for p in fork few tasks; do cp $D/$p-cur $D/$p-aa; cmp $D/$p-cur $D/$p-aa; done
cp $EV/fork-main $D/fork-pre; cp $EV/few-main $D/few-pre; cp $EV/tasks-main/rig-safe $D/tasks-pre
cp /zfs/trig-pup/standings-1118/order/bin-rayon $D/rayon
cmp -s $D/fork-cur $D/fork-new && echo "WARNING: identical fork arms"
ls $D
