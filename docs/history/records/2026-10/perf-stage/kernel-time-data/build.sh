#!/bin/sh
# build.sh SHA[:PATCH]...: each Rig (main SHA, with PATCH applied when named)
# in its own clone, built on the E-cores 12-19; then Trig 2ba0719 built by it
# with --release --pgo, trained by tools/trig/bolt-train, through slot.sh on
# the E-core release slots. Standing-4's recipe.
set -u
W=/zfs/worktrees/rig/kernel-time
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
buildrig() { # NAME SHA PATCH
  name=$1 sha=$2 patch=$3 d=$W/rig-$1
  if [ -x $d/bin/rig ]; then log "rig $name present"; return; fi
  rm -rf $d && git -c advice.detachedHead=false clone -q /zfs/trig-pup/rig $d && cd $d
  git remote set-url origin https://github.com/shreeve/rig.git && git fetch -q origin
  git -c advice.detachedHead=false checkout -q --detach $sha
  [ -n "$patch" ] && { git apply $W/$patch || { log "patch $patch FAILED"; exit 1; }; }
  start=$(date +%s)
  taskset -c 12-19 zig build -Dnexus="$NEXUS" > $d/build.log 2>&1 || { log "rig $name FAILED"; tail -5 $d/build.log; exit 1; }
  log "rig $name built in $(( $(date +%s) - start )) s: $($d/bin/rig --version 2>&1)"
  cd $W
}
buildpgo() { # NAME
  name=$1 out=$W/packs/$1-pgo rig=$W/rig-$1/bin/rig
  if [ -x $out/bin ]; then log "trig $name-pgo present"; return; fi
  for try in 1 2 3; do
    rm -rf "$out" && mkdir -p "$out/src"
    for s in $W/trig/src/*/; do ln -s "$s" "$out/src/$(basename "$s")"; done
    cp $W/trig/tools/trig/main.rig "$out/src/main.rig"
    cd "$out/src"
    start=$(date +%s)
    RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 taskset -c 12-19 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release --pgo --pgo-profile="$out/trig.profdata" -o "$out/bin" "$out/src/main.rig" -- $W/trig/tools/trig/bolt-train "$out/bin" > "$out/build.log" 2>&1 && break
    log "trig $name-pgo try $try FAILED"; tail -5 "$out/build.log"
    grep -q 'error:' "$out/build.log" && return 1
  done
  log "trig $name-pgo built in $(( $(date +%s) - start )) s: $(sha256sum $out/bin | cut -c1-16)"
  rm -rf "$out/out"
  cd $W
}
for spec in "$@"; do
  name=${spec%%=*}; rest=${spec#*=}; sha=${rest%%:*}; patch=""; case $rest in *:*) patch=${rest#*:};; esac
  buildrig $name $sha "$patch"
done
for spec in "$@"; do buildpgo ${spec%%=*}; done
log done
