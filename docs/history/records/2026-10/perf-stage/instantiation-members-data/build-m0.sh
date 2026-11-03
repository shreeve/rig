#!/bin/sh
W=$(cd "$(dirname "$0")" && pwd); R=$(/Users/shreeve/Data/Code/rig/tools/baseline 6750e8fe8)
cd "$W/m0" && RIG_OUT_DIR="$W/m0/out" RIG_NO_CRASH_REPORT=1 $R build --release -o "$W/m0/bin" src/main.rig > build.log 2>&1; echo "m0 exit=$? $(date +%T) rig=$R"
