#!/bin/sh
# On pup: Rig main 344257fc0 in two arms, main and pr (src/unordered.zig
# from the PR), each built on cores 10,11; then Trig 2ba0719 built by each
# with --release --pgo, trained by tools/trig/bolt-train, through slot.sh.
set -u
W=/zfs/worktrees/rig/rehash-x86
T=/zfs/trig-pup/full/trig
RIG=344257fc0
TRIG=2ba0719
NEXUS=/zfs/rig/nexus/bin/nexus
export TRIG_RELEASE_SLOTS='10,11 10,11 10,11'
mkdir -p $W/packs && cd $W
log() { echo "$(date '+%H:%M:%S') $*"; }
if [ ! -d $W/trig/src ]; then
  mkdir -p $W/trig && git -C $T archive $TRIG src tools/trig | tar -x -C $W/trig
  mkdir -p $W/trig/misc && cp -a $T/misc/projects $W/trig/misc/projects
fi
buildrig() {
  d=$W/rig-$1
  if [ -x $d/bin/rig ]; then log "rig $1 present"; return; fi
  rm -rf $d && git -c advice.detachedHead=false clone -q /zfs/trig-pup/rig $d && cd $d
  git remote set-url origin https://github.com/shreeve/rig.git && git fetch -q origin
  git -c advice.detachedHead=false checkout -q --detach $RIG
  [ $1 = pr ] && cp $W/unordered-pr.zig src/unordered.zig
  git diff --stat | tail -1
  sh /zfs/trig-pup/trial/slot.sh zig build -Dnexus="$NEXUS" > $d/build.log 2>&1 || { log "rig $1 FAILED"; tail -5 $d/build.log; exit 1; }
  log "rig $1 built: $($d/bin/rig --version 2>&1)"
  cd $W
}
buildpgo() {
  out=$W/packs/$1-pgo rig=$W/rig-$1/bin/rig
  if [ -x $out/bin ]; then log "trig $1-pgo present"; return; fi
  for try in 1 2 3; do
    rm -rf "$out" && mkdir -p "$out/src"
    for s in $W/trig/src/*/; do ln -s "$s" "$out/src/$(basename "$s")"; done
    cp $W/trig/tools/trig/main.rig "$out/src/main.rig"
    cd "$out/src"
    RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release --pgo --pgo-profile="$out/trig.profdata" -o "$out/bin" "$out/src/main.rig" -- $W/trig/tools/trig/bolt-train "$out/bin" > "$out/build.log" 2>&1 && break
    log "trig $1-pgo try $try FAILED"; tail -5 "$out/build.log"
    grep -q 'error:' "$out/build.log" && return 1
  done
  log "trig $1-pgo built: $(sha256sum $out/bin | cut -c1-16)"
  rm -rf "$out/out"
  cd $W
}
for a in main pr; do buildrig $a; done
for a in main pr; do buildpgo $a; done
log done
