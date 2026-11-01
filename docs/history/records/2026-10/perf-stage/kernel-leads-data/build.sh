#!/bin/sh
# build.sh [trig]: on pup (only its Rig builds were used; see emit.sh and mk.sh), Rig origin/main BASE and each arm (BASE with
# ARM.patch) in clones of their own, built on E-cores 12-19; then, given
# "trig", Trig main built by each with `rig build --release` through
# slot.sh on E-core slots. Plain builds, no switch in any.
set -u
W=/zfs/worktrees/rig/kernel-leads
T=/zfs/trig-pup/full/trig
TRIG=${TRIG:-fb60a18}
BASE=${BASE:-e4ba6de3c}
NEXUS=/zfs/rig/nexus/bin/nexus
export TRIG_RELEASE_SLOTS=${TRIG_RELEASE_SLOTS:-'12,13 14,15 16,17'}
mkdir -p $W && cd $W
log() { echo "$(date '+%H:%M:%S') $*"; }
if [ ! -d $W/trig/src ]; then
  mkdir -p $W/trig && git -C $T archive $TRIG src tools/trig | tar -x -C $W/trig
fi
buildrig() {
  arm=$1 d=$W/rig-$1
  if [ -x $d/bin/rig ]; then log "rig $arm present"; return; fi
  rm -rf $d && git -c advice.detachedHead=false clone -q /zfs/trig-pup/rig $d && cd $d
  git remote set-url origin https://github.com/shreeve/rig.git && git fetch -q origin
  git -c advice.detachedHead=false checkout -q --detach $BASE
  [ -f $W/$arm.patch ] && { git apply $W/$arm.patch || exit 1; }
  start=$(date +%s)
  taskset -c 12-19 zig build -Dnexus="$NEXUS" > $d/build.log 2>&1 || { log "rig $arm FAILED"; tail -20 $d/build.log; exit 1; }
  log "rig $arm built in $(( $(date +%s) - start )) s: $($d/bin/rig --version 2>&1)"
  cd $W
}
buildtrig() {
  arm=$1 out=$W/packs/$1 rig=$W/rig-$1/bin/rig
  if [ -x $out/bin ]; then log "trig $arm present"; return; fi
  rm -rf "$out" && mkdir -p "$out/src"
  for s in $W/trig/src/*/; do ln -s "$s" "$out/src/$(basename "$s")"; done
  cp $W/trig/tools/trig/main.rig "$out/src/main.rig"
  cd "$out/src"
  start=$(date +%s)
  RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release -o "$out/bin" "$out/src/main.rig" > "$out/build.log" 2>&1 || { log "trig $arm FAILED"; tail -5 "$out/build.log"; return 1; }
  log "trig $arm built in $(( $(date +%s) - start )) s: $(sha256sum $out/bin | cut -c1-16)"
  rm -rf "$out/out"
  cd $W
}
ARMS=${ARMS:-main l1 l2 l3 all}
for a in $ARMS; do buildrig $a; done
if [ "${1:-}" = trig ]; then
  # Two at a time, as slot.sh allows.
  set -- $ARMS
  while [ $# -gt 0 ]; do
    buildtrig $1 & p1=$!
    [ $# -gt 1 ] && { buildtrig $2 & p2=$!; wait $p2; shift; }
    wait $p1; shift
  done
fi
log done
