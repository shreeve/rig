#!/bin/sh
# On pup: Rig main af6e0e6bf in its own clone, built on the E-cores 12-19
# (another job timed on a P-core); then Trig 2ba0719 (Trig main on
# 2026-10-30, as on 2026-10-29) built by it with --release --pgo, trained by
# tools/trig/bolt-train as tools/trig/pgo builds it, through slot.sh on the
# E-core release slots. Standing-3's PGO build (Trig 2ba0719 by 1b2f4b59d)
# is copied when its sha256 matches that record's build.out.
set -u
W=/zfs/worktrees/rig/tsrs-standing-4
OLD=/zfs/worktrees/rig/tsrs-standing-3
T=/zfs/trig-pup/full/trig
TRIG=2ba0719
NEXUS=/zfs/rig/nexus/bin/nexus
export TRIG_RELEASE_SLOTS='12,13 14,15 16,17'
mkdir -p $W && cd $W
log() { echo "$(date '+%H:%M:%S') $*"; }
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
  taskset -c 12-19 zig build -Dnexus="$NEXUS" > $d/build.log 2>&1 || { log "rig $sha FAILED"; tail -5 $d/build.log; exit 1; }
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
    RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 taskset -c 12-19 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release --pgo --pgo-profile="$out/trig.profdata" -o "$out/bin" "$out/src/main.rig" -- $W/trig/tools/trig/bolt-train "$out/bin" > "$out/build.log" 2>&1 && break
    log "trig $sha-pgo try $try FAILED"; tail -5 "$out/build.log"
    grep -q 'error:' "$out/build.log" && return 1
  done
  log "trig $sha-pgo built in $(( $(date +%s) - start )) s: $(sha256sum $out/bin | cut -c1-16)"
  rm -rf "$out/out"
  cd $W
}
buildrig af6e0e6bf
mkdir -p $W/packs/1b2f4b59d-pgo
cp -a $OLD/packs/1b2f4b59d-pgo/bin $OLD/packs/1b2f4b59d-pgo/build.log $W/packs/1b2f4b59d-pgo/
log "1b2f4b59d-pgo (standing-3's) copied: $(sha256sum $W/packs/1b2f4b59d-pgo/bin | cut -c1-16)"
buildpgo af6e0e6bf
log done
