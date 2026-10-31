#!/bin/sh
# On pup: Rig main and the jit arm (main with jit.patch) in clones of
# their own, built on the E-cores; then, given "trig", Trig 2ba0719 built
# by each with --release --pgo, trained by tools/trig/bolt-train, through
# slot.sh (E-core slots while someone times). Separate plain builds.
set -u
W=/zfs/worktrees/rig/table-huge
T=/zfs/trig-pup/full/trig
TRIG=2ba0719
BASE=${BASE:-3296a2feb}
NEXUS=/zfs/rig/nexus/bin/nexus
export TRIG_RELEASE_SLOTS=${TRIG_RELEASE_SLOTS:-'12,13 14,15 16,17'}
mkdir -p $W && cd $W
log() { echo "$(date '+%H:%M:%S') $*"; }
if [ ! -d $W/trig/src ]; then
  mkdir -p $W/trig && git -C $T archive $TRIG src tools/trig | tar -x -C $W/trig
  mkdir -p $W/trig/misc && cp -a $T/misc/projects $W/trig/misc/projects
fi
buildrig() {
  arm=$1 d=$W/rig-$1
  if [ -x $d/bin/rig ]; then log "rig $arm present"; return; fi
  rm -rf $d && git -c advice.detachedHead=false clone -q /zfs/trig-pup/rig $d && cd $d
  git remote set-url origin https://github.com/shreeve/rig.git && git fetch -q origin
  git -c advice.detachedHead=false checkout -q --detach $BASE
  [ -f $W/$arm.patch ] && { patch -s -p1 < $W/$arm.patch || exit 1; }
  start=$(date +%s)
  taskset -c 12-19 zig build -Dnexus="$NEXUS" > $d/build.log 2>&1 || { log "rig $arm FAILED"; tail -20 $d/build.log; exit 1; }
  log "rig $arm built in $(( $(date +%s) - start )) s: $($d/bin/rig --version 2>&1)"
  cd $W
}
buildpgo() {
  arm=$1 out=$W/packs/$1 rig=$W/rig-$1/bin/rig
  if [ -x $out/bin ]; then log "trig $arm present"; return; fi
  for try in 1 2 3; do
    rm -rf "$out" && mkdir -p "$out/src"
    for s in $W/trig/src/*/; do ln -s "$s" "$out/src/$(basename "$s")"; done
    cp $W/trig/tools/trig/main.rig "$out/src/main.rig"
    cd "$out/src"
    start=$(date +%s)
    RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 taskset -c 12-19 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release --pgo --pgo-profile="$out/trig.profdata" -o "$out/bin" "$out/src/main.rig" -- $W/trig/tools/trig/bolt-train "$out/bin" > "$out/build.log" 2>&1 && break
    log "trig $arm try $try FAILED"; tail -5 "$out/build.log"
    grep -q 'error:' "$out/build.log" && return 1
  done
  log "trig $arm built in $(( $(date +%s) - start )) s: $(sha256sum $out/bin | cut -c1-16)"
  rm -rf "$out/out"
  cd $W
}
for a in ${ARMS:-main jit}; do buildrig $a; done
[ "${1:-}" = trig ] && for a in ${ARMS:-main jit}; do buildpgo $a; done
log done
