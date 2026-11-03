#!/bin/sh
W=$(cd "$(dirname "$0")" && pwd); R=/Users/shreeve/Data/Code/worktrees/rig/word-objects/bin/rig
cp $R $W/wo/rig
cd "$W/wo" && RIG_OUT_DIR="$W/wo/out" RIG_NO_CRASH_REPORT=1 $W/wo/rig build --release -o "$W/wo/bin" src/main.rig > build.log 2>&1; echo "wo exit=$? $(date +%T)"
