#!/bin/sh
# mk.sh ARM...: compile v/ARM (Trig's package, emitted on pup by emit.sh)
# for pup (x86-64 Linux, meteorlake) as `rig build --release` does, two at
# a time through Rig's tools/heavy.
W=$(cd "$(dirname "$0")" && pwd); R=$HOME/Data/Code/worktrees/rig/kernel-leads
mkdir -p "$W/bin" "$W/logs"
for a in "$@"; do
  (
  while [ -e "$HOME/Data/Code/mumps-compare/.mac-quiet" ]; do sleep 60; done
  start=$(date +%s)
  "$R/tools/heavy" zig build-exe -Osafe -fomit-frame-pointer -fno-stack-protector -target x86_64-linux.7.0...7.0-gnu.2.43 -mcpu=meteorlake --cache-dir "$W/cache/$a" "$W/v/$a/__rig_main.zig" -femit-bin="$W/bin/$a" > "$W/logs/build-$a.log" 2>&1
  e=$?
  echo "$(date +%T) $a exit=$e in $(( $(date +%s) - start )) s $(shasum -a 256 $W/bin/$a 2>/dev/null | cut -c1-16)" | tee -a "$W/logs/builds.txt"
  rm -rf "$W/cache/$a"
  ) &
done
wait
