#!/bin/sh
# attr.sh KT [PROJECTS]: trace one run of the prototype Trig build with
# RIG_KT=KT on each project, pinned to E-core 14, into attr/PROJ.KT.trace,
# and attribute it (attr.py) into attr/PROJ.KT.txt.
set -u
KT=$1; PROJS=${2:-ts-pattern zod3}
W=/zfs/worktrees/rig/kernel-time
P=$W/trig/misc/projects
O=$W/attr; mkdir -p $O
cp -f $W/packs/proto-rel/bin $O/trigkt
for proj in $PROJS; do
  cd $P/$proj
  sudo bpftrace -q -B line -o $O/$proj.$KT.trace $W/trace.bt trigkt > $O/bt.err 2>&1 &
  bp=$!
  sleep 4
  RIG_KT=$KT taskset -c 14 $O/trigkt -p tsconfig.trig.json --noEmit --singleThreaded > $O/$proj.$KT.out 2>&1
  sleep 1
  sudo pkill -INT -f "bpftrace -q -B line -o $O/$proj.$KT.trace"
  wait $bp
  python3 $W/attr.py $O/$proj.$KT.trace > $O/$proj.$KT.txt
  echo "== $proj RIG_KT=$KT"; cat $O/$proj.$KT.txt
done
