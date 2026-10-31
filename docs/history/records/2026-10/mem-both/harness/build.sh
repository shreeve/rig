#!/bin/sh
# build.sh ARM...: for each arm (alloc-ARM.zig over Rig BASE's src/alloc.zig):
# a Rig clone built on the E-cores, kv built by it, the mimalloc-bench shim
# over it. TRIG="ARM..." also builds Trig (row 17's recipe: --release --pgo,
# trained by tools/trig/bolt-train) through slot.sh on the E-core slots.
set -u
W=/zfs/worktrees/rig/mem-both
BASE=${BASE:-179c50afa}
T=/zfs/trig-pup/full/trig
TRIGC=2ba0719
NEXUS=/zfs/rig/nexus/bin/nexus
export TRIG_RELEASE_SLOTS='12,13 14,15 16,17'
cd $W
log() { echo "$(date '+%H:%M:%S') $*"; }
[ -x $W/load ] || (rustc -O -o load load.rs && rustc -O -o hold hold.rs) || exit 1
if [ ! -d $W/trig/src ]; then
  mkdir -p $W/trig && git -C $T archive $TRIGC src tools/trig | tar -x -C $W/trig
  mkdir -p $W/trig/misc && cp -a $T/misc/projects $W/trig/misc/projects
fi
for arm in "$@"; do
  d=$W/rig-$arm
  if [ ! -x $d/bin/rig ]; then
    rm -rf $d && git -c advice.detachedHead=false clone -q /zfs/trig-pup/rig $d && cd $d
    git remote set-url origin https://github.com/shreeve/rig.git && git fetch -q origin
    git -c advice.detachedHead=false checkout -q --detach $BASE
    cp $W/alloc-$arm.zig src/alloc.zig
    taskset -c 12-19 zig build -Dnexus="$NEXUS" > $d/build.log 2>&1 || { log "rig $arm FAILED"; tail -5 $d/build.log; exit 1; }
    log "rig $arm built"
    cd $W
  fi
  mkdir -p $W/kvb/$arm
  [ -x $W/kv-$arm ] || { RIG_OUT_DIR=$W/kvb/$arm taskset -c 12-19 $d/bin/rig build --release -o $W/kv-$arm $W/kv.rig > $W/kvb/$arm.log 2>&1 || { log "kv $arm FAILED"; tail -5 $W/kvb/$arm.log; }; }
  s=$W/shim/$arm; mkdir -p $s
  if [ ! -f $s/librigalloc.so ]; then
    cp /zfs/worktrees/rig-rust-ports/mbench/shim/rigalloc.zig /zfs/worktrees/rig-rust-ports/mbench/shim/build.sh $s/
    cp $W/alloc-$arm.zig $s/alloc.zig
    (cd $s && taskset -c 12-19 sh build.sh > build.log 2>&1) || { log "shim $arm FAILED"; tail -5 $s/build.log; }
  fi
  log "kv and shim $arm: $(ls $W/kv-$arm $s/librigalloc.so 2>&1 | tr '\n' ' ')"
done
for arm in ${TRIG:-}; do
  out=$W/packs/$arm-pgo rig=$W/rig-$arm/bin/rig
  [ -x $out/bin ] && continue
  for try in 1 2 3; do
    rm -rf "$out" && mkdir -p "$out/src"
    for s in $W/trig/src/*/; do ln -s "$s" "$out/src/$(basename "$s")"; done
    cp $W/trig/tools/trig/main.rig "$out/src/main.rig"
    cd "$out/src"
    RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 taskset -c 12-19 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release --pgo --pgo-profile="$out/trig.profdata" -o "$out/bin" "$out/src/main.rig" -- $W/trig/tools/trig/bolt-train "$out/bin" > "$out/build.log" 2>&1 && break
    log "trig $arm try $try FAILED"; tail -5 "$out/build.log"
    grep -q 'error:' "$out/build.log" && break
  done
  rm -rf "$out/out"; cd $W
  log "trig $arm built: $(sha256sum $out/bin 2>/dev/null | cut -c1-16)"
done
log done
