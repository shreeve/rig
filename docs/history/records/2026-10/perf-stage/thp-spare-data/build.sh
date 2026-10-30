#!/bin/sh
# On pup: Rig main 277fba515 in six arms, each in its own clone and built on
# cores 10,11, differing only in the huge-page gate (alloc.zig):
#   s128: main as it is, huge_spare = 128
#   s64, s32, s16: huge_spare = 64, 32, 16
#   always: hugeFree() is true (asks always, as 773978d1d did)
#   never: hugeFree() is false (no MADV_HUGEPAGE anywhere)
# then Trig 2ba0719 built by each with --release --pgo, trained by
# tools/trig/bolt-train as tools/trig/pgo builds it, through slot.sh on
# release slot 10,11.
set -u
W=/zfs/worktrees/rig/thp-spare
T=/zfs/trig-pup/full/trig
RIG=277fba515
TRIG=2ba0719
NEXUS=/zfs/rig/nexus/bin/nexus
ARMS=${ARMS:-"s128 s64 s32 s16 always never"}
export TRIG_RELEASE_SLOTS='10,11 10,11 10,11'
mkdir -p $W/packs && cd $W
log() { echo "$(date '+%H:%M:%S') $*"; }
if [ ! -d $W/trig/src ]; then
  mkdir -p $W/trig && git -C $T archive $TRIG src tools/trig | tar -x -C $W/trig
  mkdir -p $W/trig/misc && cp -a $T/misc/projects $W/trig/misc/projects
fi
patch_arm() { # in the clone: change alloc.zig for arm $1
  f=src/alloc.zig
  case $1 in
    s128) ;;
    s[0-9]*) sed -i "s/^const huge_spare: usize = 128;/const huge_spare: usize = ${1#s};/" $f ;;
    always) sed -i '/^pub noinline fn hugeFree() bool {/,/^}/ s/^    if (builtin.os.tag != .linux) return false;/&\n    if (true) return true;/' $f ;;
    never) sed -i '/^pub noinline fn hugeFree() bool {/,/^}/ s/^    if (builtin.os.tag != .linux) return false;/&\n    if (true) return false;/' $f ;;
  esac
  git diff --stat | tail -1
  git diff > $W/patch-$1.diff
}
buildrig() {
  d=$W/rig-$1
  if [ -x $d/bin/rig ]; then log "rig $1 present"; return; fi
  rm -rf $d && git -c advice.detachedHead=false clone -q /zfs/trig-pup/rig $d && cd $d
  git remote set-url origin https://github.com/shreeve/rig.git && git fetch -q origin
  git -c advice.detachedHead=false checkout -q --detach $RIG
  patch_arm $1
  start=$(date +%s)
  taskset -c 10,11 zig build -Dnexus="$NEXUS" > $d/build.log 2>&1 || { log "rig $1 FAILED"; tail -5 $d/build.log; exit 1; }
  log "rig $1 built in $(( $(date +%s) - start )) s: $($d/bin/rig --version 2>&1)"
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
    start=$(date +%s)
    RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release --pgo --pgo-profile="$out/trig.profdata" -o "$out/bin" "$out/src/main.rig" -- $W/trig/tools/trig/bolt-train "$out/bin" > "$out/build.log" 2>&1 && break
    log "trig $1-pgo try $try FAILED"; tail -5 "$out/build.log"
    grep -q 'error:' "$out/build.log" && return 1
  done
  log "trig $1-pgo built in $(( $(date +%s) - start )) s: $(sha256sum $out/bin | cut -c1-16)"
  rm -rf "$out/out"
  cd $W
}
for a in $ARMS; do buildrig $a; done
for a in $ARMS; do buildpgo $a; done
log done
