#!/bin/sh
# mk.sh ARM...: compile v/ARM as rig build --release does (zig build-exe
# -Osafe -fomit-frame-pointer), cross for pup (x86_64 Linux, meteorlake,
# as ids-ceiling/mk.sh), one at a time through tools/heavy.
W=${W:-$PWD}; R=$HOME/Data/Code/worktrees/rig/conc-audit
tgt="-target x86_64-linux.7.0...7.0-gnu.2.43 -mcpu=meteorlake"
mkdir -p $W/bin $W/logs
for a in "$@"; do
  while [ -e $HOME/Data/Code/mumps-compare/.mac-quiet ]; do sleep 60; done
  start=$(date +%s)
  $R/tools/heavy zig build-exe -Osafe -fomit-frame-pointer $tgt --cache-dir $W/cache/$a $W/v/$a/__rig_main.zig -femit-bin=$W/bin/$a > $W/logs/build-$a.log 2>&1
  e=$?
  echo "$(date +%T) $a exit=$e in $(( $(date +%s) - start )) s" | tee -a $W/logs/builds.txt
  rm -rf $W/cache/$a
done
