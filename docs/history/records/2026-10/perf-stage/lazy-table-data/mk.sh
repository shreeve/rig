#!/bin/sh
# mk.sh TARGET ARM...: compile v-ARM/pkg as `rig build --release` does, one at a time through Rig's tools/heavy.
W=$(cd "$(dirname "$0")/.." && pwd); R=$HOME/Data/Code/worktrees/rig/lazy-table
t=$1; shift
case $t in
  x86) tgt="-target x86_64-linux.7.0...7.0-gnu.2.43 -mcpu=meteorlake" ;;
  mac) tgt= ;;
esac
mkdir -p "$W/bin/$t" "$W/logs"
for a in "$@"; do
  while [ -e "$HOME/Data/Code/mumps-compare/.mac-quiet" ]; do sleep 60; done
  start=$(date +%s)
  "$R/tools/heavy" zig build-exe -Osafe -fomit-frame-pointer $tgt --cache-dir "$W/cache/$t-$a" "$W/v-$a/pkg/__rig_main.zig" -femit-bin="$W/bin/$t/$a" > "$W/logs/build-$t-$a.log" 2>&1
  e=$?
  echo "$(date +%T) $t $a exit=$e in $(( $(date +%s) - start )) s" | tee -a "$W/logs/builds.txt"
  rm -rf "$W/cache/$t-$a"
done
