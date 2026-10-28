#!/bin/sh
# On pup: Rig with each experiment's patch, each in its own clone, built on
# cores 10,11; then Trig 403a823 built by each with --release --pgo, trained
# by tools/trig/bolt-train as tools/trig/pgo builds it, through slot.sh on
# release slot 10,11 (the list three long, so that any of its locks will do).
#   c: 2c01f07dd (the #760 revert's src/, identical) with no segment advice
#   d: 2c01f07dd with no MADV_HUGEPAGE anywhere
#   e: 773978d1d with every advice gated on free 2 MiB blocks (buddyinfo), 16 spare
#   e2: as e, 128 spare
#   g: the thp-gate branch (build.sh g 5b103b53f none)
# (a) 773978d1d and (b) 2c01f07dd are tsrs-standing-2's PGO builds.
set -u
W=/zfs/worktrees/rig/thp-frag
SRC=/zfs/worktrees/rig/tsrs-standing-2/trig
export TRIG_RELEASE_SLOTS='10,11 10,11 10,11'
mkdir -p $W/packs && cd $W
log() { echo "$(date '+%H:%M:%S') $*"; }
buildrig() { # name base patch
  d=$W/rig-$1
  if [ -x $d/bin/rig ]; then log "rig $1 present"; return; fi
  rm -rf $d && git -c advice.detachedHead=false clone -q /zfs/trig-pup/rig $d && cd $d
  git remote set-url origin https://github.com/shreeve/rig.git && git fetch -q origin
  git -c advice.detachedHead=false checkout -q --detach $2
  [ "$3" = none ] || git apply $W/$3 || { log "rig $1: patch failed"; exit 1; }
  start=$(date +%s)
  taskset -c 10,11 zig build -Dnexus="$HOME/Data/Code/nexus/bin/nexus" > $d/build.log 2>&1 || { log "rig $1 FAILED"; tail -20 $d/build.log; exit 1; }
  log "rig $1 built in $(( $(date +%s) - start )) s: $($d/bin/rig --version 2>&1)"
  cd $W
}
buildpgo() {
  name=$1 out=$W/packs/$1-pgo rig=$W/rig-$1/bin/rig
  if [ -x $out/bin ]; then log "trig $name-pgo present"; return; fi
  for try in 1 2 3; do
    rm -rf "$out" && mkdir -p "$out/src"
    for s in $SRC/src/*/; do ln -s "$s" "$out/src/$(basename "$s")"; done
    cp $SRC/tools/trig/main.rig "$out/src/main.rig"
    cd "$out/src"
    start=$(date +%s)
    RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release --pgo --pgo-profile="$out/trig.profdata" -o "$out/bin" "$out/src/main.rig" -- $SRC/tools/trig/bolt-train "$out/bin" > "$out/build.log" 2>&1 && break
    log "trig $name-pgo try $try FAILED"; tail -5 "$out/build.log"
  done
  log "trig $name-pgo built in $(( $(date +%s) - start )) s: $(sha256sum $out/bin | cut -c1-16)"
  rm -rf "$out/out"
  cd $W
}
buildrig ${1:-g} ${2:-5b103b53f} ${3:-none}
buildpgo ${1:-g}
log done
