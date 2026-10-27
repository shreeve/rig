#!/bin/sh
# jsonbuild.sh RIG NAME: map-stage's std.json programs built by RIG into json/NAME.
set -u
W=/zfs/worktrees/rig/std-hash
S=/zfs/worktrees/rig/map-stage/json/base
for d in $S/*-rig-*; do
  b=$(basename $d); o=$W/json/$2/$b
  mkdir -p $o && cp $d/main.rig $d/json.rig $o/
  case $b in *-rig-fast) f=--release=fast;; *) f=--release;; esac
  (cd $o && XDG_CACHE_HOME=/zfs/rig/xdg-cache RIG_OUT_DIR=$o/out nice $1 build $f -o prog main.rig > build.log 2>&1 && rm -rf out) || echo "FAIL $b"
done
