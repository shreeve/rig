#!/bin/sh
# mk.sh TARGET ARM...: compile v/ARM (the package ceil.py wrote) as rig build
# --release does, zig build-exe -Osafe -fomit-frame-pointer, one at a time
# through tools/heavy. TARGET x86 builds for pup (its native target, given
# by name: the .text is byte-identical to a build on pup), mac for this Mac.
W=$(cd "$(dirname "$0")" && pwd); R=$HOME/Data/Code/worktrees/rig/ids-ceiling
t=$1; shift
case $t in
  x86) tgt="-target x86_64-linux.7.0...7.0-gnu.2.43 -mcpu=meteorlake" ;;
  mac) tgt= ;;
esac
mkdir -p $W/bin/$t $W/logs
for a in "$@"; do
  while [ -e $HOME/Data/Code/mumps-compare/.mac-quiet ]; do sleep 60; done
  d=$W/v/$a; start=$(date +%s)
  $R/tools/heavy zig build-exe -Osafe -fomit-frame-pointer $tgt --cache-dir $W/cache/$t-$a $d/__rig_main.zig -femit-bin=$W/bin/$t/$a > $W/logs/build-$t-$a.log 2>&1
  e=$?
  echo "$(date +%T) $t $a exit=$e in $(( $(date +%s) - start )) s" | tee -a $W/logs/builds.txt
  rm -rf $W/cache/$t-$a
done
