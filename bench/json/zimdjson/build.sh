#!/bin/sh
# usage: build.sh dom|od fast|safe
# Clones zimdjson at the pinned revision into ./upstream (once), patches it
# to build on Zig 0.17 (zig-0.17.patch), and builds ./prog-API-MODE.
set -e
W=$(cd "$(dirname "$0")" && pwd)
api=$1; mode=$2
case $api in dom|od) ;; *) echo "usage: $0 dom|od fast|safe" >&2; exit 2;; esac
case $mode in fast) O=-OReleaseFast;; safe) O=-OReleaseSafe;; *) echo "usage: $0 dom|od fast|safe" >&2; exit 2;; esac
cd "$W"
if [ ! -d upstream/.git ]; then
  git clone https://github.com/EzequielRamis/zimdjson.git upstream
  git -C upstream checkout --detach aa22af403d769fb8c70c6c529389b1977f5cd558
  git -C upstream apply "$W/zig-0.17.patch"
fi
zig build-exe $O -j"${CPUQ_CORES:-2}" \
  --cache-dir "$W/.zc" --global-cache-dir "$W/.zgc" \
  --dep zimdjson --dep cfg -Mroot=bench.zig \
  --dep build_options -Mzimdjson=upstream/src/zimdjson.zig \
  -Mcfg=cfg-$api.zig \
  -Mbuild_options=build_options.zig \
  -femit-bin="$W/prog-$api-$mode" --name prog-$api-$mode
