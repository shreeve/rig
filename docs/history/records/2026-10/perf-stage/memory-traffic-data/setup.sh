#!/bin/sh
# On pup: Rig main and Rig main with the private allocation trace
# (alloc-trace.diff, never on main), and Trig 403a823 built by them:
#   rel    rig-main, --release (the build Trig's A/Bs use)
#   fp     rig-main, --release, RIG_FRAME_POINTERS=1
#   trace  rig-trace, --release, RIG_FRAME_POINTERS=1 RIG_ALLOC_TRACE=1
# Every build on release slot 10,11 through slot.sh.
set -u
W=/zfs/worktrees/rig/memory-traffic
T=/zfs/trig-pup/full/trig
TRIG=403a823
RIG=${RIG:-4d80efe17}
export TRIG_RELEASE_SLOTS='10,11'
mkdir -p $W && cd $W
log() { echo "$(date '+%H:%M:%S') $*"; }
[ -d $W/trig/src ] || { mkdir -p $W/trig && git -C $T archive $TRIG src tools/trig | tar -x -C $W/trig; }
buildrig() {
  name=$1 d=$W/rig-$1
  if [ -x $d/bin/rig ]; then log "rig $name present"; return; fi
  rm -rf $d && git -c advice.detachedHead=false clone -q /zfs/trig-pup/rig $d && cd $d
  git remote set-url origin https://github.com/shreeve/rig.git && git fetch -q origin
  git -c advice.detachedHead=false checkout -q --detach $RIG
  [ $name = trace ] && git apply $W/alloc-trace.diff
  start=$(date +%s)
  sh /zfs/trig-pup/trial/slot.sh zig build -Dnexus="$HOME/Data/Code/nexus/bin/nexus" > $d/build.log 2>&1 || { log "rig $name FAILED"; tail -5 $d/build.log; }
  log "rig $name built in $(( $(date +%s) - start )) s"
  cd $W
}
buildtrig() {
  name=$1 rig=$W/rig-$2/bin/rig out=$W/packs/$1
  shift 2
  if [ -x $out/bin ]; then log "trig $name present"; return; fi
  rm -rf "$out" && mkdir -p "$out/src"
  for d in $W/trig/src/*/; do ln -s "$d" "$out/src/$(basename "$d")"; done
  cp $W/trig/tools/trig/main.rig "$out/src/main.rig"
  cd "$out/src"
  start=$(date +%s)
  env "$@" RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release -o "$out/bin" "$out/src/main.rig" > "$out/build.log" 2>&1 || { log "trig $name FAILED"; tail -5 "$out/build.log"; }
  log "trig $name built in $(( $(date +%s) - start )) s"
  cd $W
}
buildrig main
buildrig trace
buildtrig rel main X=1
buildtrig trace trace RIG_FRAME_POINTERS=1 RIG_ALLOC_TRACE=1
buildtrig fp main RIG_FRAME_POINTERS=1
log done
