#!/bin/bash
# traces.sh N: N traced runs at 10 workers (t10/) and N at one worker (t1/), alternating.
S=$(dirname "$0"); cd $S/prog
rm -rf t10 t1; mkdir -p t10 t1
for i in $(seq 1 $1); do
  STARTUP_MODE=mark RIG_START_TRACE=1 ./rig-inst > t10/run-$i.out 2> t10/run-$i.err
  STARTUP_MODE=mark RIG_START_TRACE=1 RIG_WORKERS=1 ./rig-inst > t1/run-$i.out 2> t1/run-$i.err
done
