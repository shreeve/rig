#!/bin/sh
# On pup: Trig 403a823 (src from tsrs-standing) built --release by each Rig on slot 10,11.
set -u
O=/zfs/worktrees/rig/mwk; T=/zfs/trig-pup/full/trig; TS=/zfs/worktrees/rig/tsrs-standing/trig
export TRIG_RELEASE_SLOTS='10,11'
log() { echo "$(date '+%H:%M:%S') $*"; }
for v in ${VS:-base b4 il}; do
  out=$O/packs/$v rig=$O/rig-$v/bin/rig
  if [ -x $out/bin ]; then log "trig $v present"; continue; fi
  rm -rf "$out" && mkdir -p "$out/src"
  for d in $TS/src/*/; do ln -s "$d" "$out/src/$(basename "$d")"; done
  cp $TS/tools/trig/main.rig "$out/src/main.rig"
  cd "$out/src"; start=$(date +%s)
  RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release -o "$out/bin" "$out/src/main.rig" > "$out/build.log" 2>&1 || { log "trig $v FAILED"; tail -5 "$out/build.log"; }
  log "trig $v built in $(( $(date +%s) - start )) s"
  rm -rf "$out/out"; cd $O
done
