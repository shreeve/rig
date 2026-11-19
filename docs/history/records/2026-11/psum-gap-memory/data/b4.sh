#!/bin/bash
# b4.sh: builds the arms of m4.py on E-cores, only while no slot is open.
set -eu
D=/zfs/trig-pup/psum-gap/mem/b4; mkdir -p $D
E="taskset -c 12-19"
free_slot() { for i in $(seq 360); do /zfs/trig-pup/bin/pup-slot state | grep -q "slot=none" && return 0; sleep 10; done; echo "no free slot"; exit 1; }
for pair in main:08b2caf1a new:89f2fc195; do
  a=${pair%%:*}; S=/zfs/trig-pup/rig-${pair#*:}
  cd $S
  for p in fork:docs/history/records/2026-11/concurrency-bench-remeasure/fork/fork.rig tasks:bench/tasks/tasks.rig net:bench/net/net.rig; do
    free_slot
    RIG_OUT_DIR=$D/pkg-${p%%:*}-$a $E bin/rig build --release -o $D/${p%%:*}-$a $S/${p#*:}
  done
done
for p in fork tasks net; do cp $D/$p-main $D/$p-aa; cmp $D/$p-main $D/$p-aa; done
cp /zfs/trig-pup/standings-1118/fork/rayon $D/rayon
ls -la $D
