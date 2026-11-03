#!/bin/sh
# build.sh NAME: release-build the pack NAME with the gap map's Rig
W=$(cd "$(dirname "$0")" && pwd); R=/Users/shreeve/Data/Code/rig/.git/rig-baseline/43e1f65f49f7627052f0f20403ea5b92bd144c5a/rig
cd "$W/$1" && RIG_OUT_DIR="$W/$1/out" RIG_NO_CRASH_REPORT=1 $R build --release -o "$W/$1/bin" src/main.rig > build.log 2>&1; echo "$1 exit=$? $(date +%T)"
