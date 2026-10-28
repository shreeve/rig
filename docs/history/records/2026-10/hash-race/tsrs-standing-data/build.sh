#!/bin/sh
# On pup: three Rigs (main 36422da59, #735 f7edd5cb5, before #735 a38ff34b7)
# and Trig 403a823 built by each (plain --release), plus Trig's PGO build by
# Rig main; every build on release slot 10,11 alone.
set -u
W=/zfs/worktrees/rig/tsrs-standing
T=/zfs/trig-pup/full/trig
TRIG=403a823
export TRIG_RELEASE_SLOTS='10,11'
mkdir -p $W && cd $W
log() { echo "$(date '+%H:%M:%S') $*"; }
# Trig's source at $TRIG, apart from the full checkout the cron moves.
if [ ! -d $W/trig/src ]; then
  mkdir -p $W/trig && git -C $T archive $TRIG src tools/trig | tar -x -C $W/trig
fi
buildrig() {
  sha=$1 d=$W/rig-$1
  if [ -x $d/bin/rig ]; then log "rig $sha present"; return; fi
  rm -rf $d && git -c advice.detachedHead=false clone -q /zfs/trig-pup/rig $d && cd $d
  git remote set-url origin https://github.com/shreeve/rig.git && git fetch -q origin
  git -c advice.detachedHead=false checkout -q --detach $sha
  start=$(date +%s)
  sh /zfs/trig-pup/trial/slot.sh zig build -Dnexus="$HOME/Data/Code/nexus/bin/nexus" > $d/build.log 2>&1 || { log "rig $sha FAILED"; tail -5 $d/build.log; }
  log "rig $sha built in $(( $(date +%s) - start )) s: $($d/bin/rig --version 2>&1)"
  cd $W
}
buildtrig() {
  sha=$1 mode=$2 name=$1-$2 out=$W/packs/$1-$2 rig=$W/rig-$1/bin/rig
  if [ -x $out/bin ]; then log "trig $name present"; return; fi
  rm -rf "$out" && mkdir -p "$out/src"
  for d in $W/trig/src/*/; do ln -s "$d" "$out/src/$(basename "$d")"; done
  cp $W/trig/tools/trig/main.rig "$out/src/main.rig"
  cd "$out/src"
  start=$(date +%s)
  if [ $mode = pgo ]; then
    RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release --pgo --pgo-profile="$out/trig.profdata" -o "$out/bin" "$out/src/main.rig" -- $T/tools/trig/bolt-train "$out/bin" > "$out/build.log" 2>&1 || { log "trig $name FAILED"; tail -5 "$out/build.log"; }
  else
    RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release -o "$out/bin" "$out/src/main.rig" > "$out/build.log" 2>&1 || { log "trig $name FAILED"; tail -5 "$out/build.log"; }
  fi
  log "trig $name built in $(( $(date +%s) - start )) s"
  rm -rf "$out/out"
  cd $W
}
for s in 36422da59 f7edd5cb5 a38ff34b7; do buildrig $s; done
for s in 36422da59 f7edd5cb5 a38ff34b7; do buildtrig $s rel; done
buildtrig 36422da59 pgo
log done
