#!/bin/sh
# On pup: Rig main (373b6aed3) and the emit-inplace branch (main plus
# inplace.diff), and Trig 403a823 built --release by each on slot 10,11.
set -u
W=/zfs/worktrees/rig/emit-inplace
T=/zfs/trig-pup/full/trig
TRIG=403a823
RIG=373b6aed3
export TRIG_RELEASE_SLOTS='10,11'
cd $W
log() { echo "$(date '+%H:%M:%S') $*"; }
[ -d $W/trig/src ] || { mkdir -p $W/trig && git -C $T archive $TRIG src tools/trig | tar -x -C $W/trig; }
buildrig() {
  name=$1 d=$W/rig-$1
  if [ -x $d/bin/rig ] && [ "${REBUILD:-}" != $name ]; then log "rig $name present"; return; fi
  if [ ! -d $d/.git ]; then
    git -c advice.detachedHead=false clone -q /zfs/trig-pup/rig $d && cd $d
    git remote set-url origin https://github.com/shreeve/rig.git && git fetch -q origin
  fi
  cd $d && git checkout -q -f --detach $RIG && git clean -qfd src std
  [ $name = new ] && git apply $W/inplace.diff
  start=$(date +%s)
  taskset -c 12-15 zig build -Dnexus="$HOME/Data/Code/nexus/bin/nexus" > $d/build.log 2>&1 || { log "rig $name FAILED"; tail -5 $d/build.log; }
  log "rig $name built in $(( $(date +%s) - start )) s"
  cd $W
}
buildtrig() {
  name=$1 rig=$W/rig-$1/bin/rig out=$W/packs/$1
  rm -rf "$out" && mkdir -p "$out/src"
  for d in $W/trig/src/*/; do ln -s "$d" "$out/src/$(basename "$d")"; done
  cp $W/trig/tools/trig/main.rig "$out/src/main.rig"
  cd "$out/src"
  start=$(date +%s)
  RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release -o "$out/bin" "$out/src/main.rig" > "$out/build.log" 2>&1 || { log "trig $name FAILED"; tail -5 "$out/build.log"; }
  log "trig $name built in $(( $(date +%s) - start )) s"
  cd $W
}
for n in "$@"; do buildrig $n; buildtrig $n; done
