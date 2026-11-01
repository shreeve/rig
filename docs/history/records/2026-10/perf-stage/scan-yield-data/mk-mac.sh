#!/bin/sh
# mk-mac.sh NAME...: compile v/NAME/pkg as `rig build --release` does
# (zig build-exe -Osafe -fomit-frame-pointer), one at a time, each
# through Rig's tools/heavy, holding while .mac-quiet exists.
S=$HOME/Data/Code/Claude/rig/rig/scan-yield-study
W=$HOME/Data/Code/worktrees/rig/scan-yield
for n in "$@"; do
  while [ -e $HOME/Data/Code/mumps-compare/.mac-quiet ]; do echo "# $(date +%T) waiting: .mac-quiet"; sleep 60; done
  d=$S/v/$n; start=$(date +%s)
  (cd $W && tools/heavy zig build-exe -Osafe -fomit-frame-pointer --cache-dir $d/pkg/.zig-cache $d/pkg/__rig_main.zig -femit-bin=$d/bin) > $d/build.log 2>&1
  e=$?
  echo "$(date +%T) $n -Osafe exit=$e in $(( $(date +%s) - start )) s"
  rm -rf $d/pkg/.zig-cache
done
