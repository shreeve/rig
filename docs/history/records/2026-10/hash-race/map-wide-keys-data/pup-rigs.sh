#!/bin/sh
# On pup: Rig 099c1bff3 (main), and main with each ordered.zig variant, built on slot 10,11.
set -u
O=/zfs/worktrees/rig/mwk
export TRIG_RELEASE_SLOTS='10,11'
cd $O
for v in ${VS:-base b4 il}; do
  d=$O/rig-$v
  if [ -x $d/bin/rig ]; then echo "rig-$v present"; continue; fi
  rm -rf $d && git -c advice.detachedHead=false clone -q /zfs/trig-pup/rig $d && cd $d
  git remote set-url origin https://github.com/shreeve/rig.git && git fetch -q origin
  git -c advice.detachedHead=false checkout -q --detach ${SHA:-099c1bff3}
  [ $v = base ] || [ $v = m7 ] || cp $O/ordered-$v.zig src/ordered.zig; [ -f $O/runtime-$v.zig ] && cp $O/runtime-$v.zig src/runtime.zig
  sh /zfs/trig-pup/trial/slot.sh zig build -Dnexus="$HOME/Data/Code/nexus/bin/nexus" > $d/build.log 2>&1 || { echo "rig-$v FAILED"; tail -5 $d/build.log; }
  echo "rig-$v built: $($d/bin/rig --version 2>&1)"
  cd $O
done
