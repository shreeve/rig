#!/bin/sh
# build-hp.sh NAME RIG: a release Trig with RIG_HEAP_PROFILE=1 from pack NAME's sources
W=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$W/hp-$1"; rm -rf "$W/hp-$1/src"; cp -R "$W/$1/src" "$W/hp-$1/src"
cd "$W/hp-$1" && RIG_HEAP_PROFILE=1 RIG_OUT_DIR="$W/hp-$1/out" RIG_NO_CRASH_REPORT=1 $2 build --release -o "$W/hp-$1/bin" src/main.rig > build.log 2>&1; echo "hp-$1 exit=$? $(date +%T)"
