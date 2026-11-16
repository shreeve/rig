#!/bin/bash
# traces-arms.sh N: N traced runs (mark mode, 10 workers) of cold, tree+mapall, eager+map16, rotating.
S=$(dirname "$0"); cd $S/prog
for d in ta-cold ta-treemap ta-eagermap; do rm -rf $d; mkdir -p $d; done
for i in $(seq 1 $1); do
  STARTUP_MODE=mark RIG_START_TRACE=1 ./rig-inst > ta-cold/run-$i.out 2> ta-cold/run-$i.err
  STARTUP_MODE=mark RIG_START_TRACE=1 RIG_X_TREE=1 RIG_X_MAPALL=1 ./rig-inst > ta-treemap/run-$i.out 2> ta-treemap/run-$i.err
  STARTUP_MODE=mark RIG_START_TRACE=1 RIG_X_EAGER=1 RIG_X_PREFAULT=16 RIG_X_NOTOUCH=1 ./rig-inst > ta-eagermap/run-$i.out 2> ta-eagermap/run-$i.err
done
