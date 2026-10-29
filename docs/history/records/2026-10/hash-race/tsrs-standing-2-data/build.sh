#!/bin/sh
# On pup: Rig main 773978d1d (#754) and main before it, 2c01f07dd (#749),
# each in its own clone, built on cores 1,2; then Trig 403a823 (Trig main on
# 2026-10-28) built by each with --release --pgo, trained by
# tools/trig/bolt-train as tools/trig/pgo builds it, on release slot 10,11.
# The PGO build by Rig 36422da59 (the 2026-10-27 record's, same Trig, same
# main.rig, same training) is copied from that record's directory.
set -u
W=/zfs/worktrees/rig/tsrs-standing-2
OLD=/zfs/worktrees/rig/tsrs-standing
T=/zfs/trig-pup/full/trig
TRIG=403a823
export TRIG_RELEASE_SLOTS='10,11'
mkdir -p $W && cd $W
log() { echo "$(date '+%H:%M:%S') $*"; }
# Trig's source at $TRIG and its projects, apart from the checkout the cron moves.
if [ ! -d $W/trig/src ]; then
  mkdir -p $W/trig && git -C $T archive $TRIG src tools/trig | tar -x -C $W/trig
  mkdir -p $W/trig/misc && cp -a $T/misc/projects $W/trig/misc/projects
fi
buildrig() {
  sha=$1 d=$W/rig-$1
  if [ -x $d/bin/rig ]; then log "rig $sha present"; return; fi
  rm -rf $d && git -c advice.detachedHead=false clone -q /zfs/trig-pup/rig $d && cd $d
  git remote set-url origin https://github.com/shreeve/rig.git && git fetch -q origin
  git -c advice.detachedHead=false checkout -q --detach $sha
  start=$(date +%s)
  taskset -c 1,2 zig build -Dnexus="$HOME/Data/Code/nexus/bin/nexus" > $d/build.log 2>&1 || { log "rig $sha FAILED"; tail -5 $d/build.log; exit 1; }
  log "rig $sha built in $(( $(date +%s) - start )) s: $($d/bin/rig --version 2>&1)"
  cd $W
}
buildpgo() {
  sha=$1 out=$W/packs/$1-pgo rig=$W/rig-$1/bin/rig
  if [ -x $out/bin ]; then log "trig $sha-pgo present"; return; fi
  for try in 1 2 3; do
    rm -rf "$out" && mkdir -p "$out/src"
    for s in $W/trig/src/*/; do ln -s "$s" "$out/src/$(basename "$s")"; done
    cp $W/trig/tools/trig/main.rig "$out/src/main.rig"
    cd "$out/src"
    start=$(date +%s)
    RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release --pgo --pgo-profile="$out/trig.profdata" -o "$out/bin" "$out/src/main.rig" -- $W/trig/tools/trig/bolt-train "$out/bin" > "$out/build.log" 2>&1 && break
    log "trig $sha-pgo try $try FAILED"; tail -5 "$out/build.log"
  done
  log "trig $sha-pgo built in $(( $(date +%s) - start )) s: $(sha256sum $out/bin | cut -c1-16)"
  rm -rf "$out/out"
  cd $W
}
for s in 773978d1d 2c01f07dd; do buildrig $s; done
for s in 773978d1d 2c01f07dd; do buildpgo $s; done
if [ ! -x $W/packs/36422da59-pgo/bin ]; then
  mkdir -p $W/packs/36422da59-pgo && cp -a $OLD/packs/36422da59-pgo/bin $OLD/packs/36422da59-pgo/build.log $W/packs/36422da59-pgo/
fi
log "36422da59-pgo copied: $(sha256sum $W/packs/36422da59-pgo/bin | cut -c1-16)"
log done
