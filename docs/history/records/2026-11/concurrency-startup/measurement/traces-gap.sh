#!/bin/bash
# traces-gap.sh N: N traced runs at 10 workers with psum3 after 100 ms asleep (tg/).
S=$(dirname "$0"); cd $S/prog
rm -rf tg; mkdir -p tg
for i in $(seq 1 $1); do
  STARTUP_MODE=markgap RIG_START_TRACE=1 ./rig-inst > tg/run-$i.out 2> tg/run-$i.err
done
