#!/bin/bash
# zr.sh file.rig [mode]: emit, swap in runtime_patched.zig, run with zig
D=$(dirname $0)
f=$1; mode=${2:-Debug}
out=$(/Users/shreeve/Data/Code/rig/bin/rig emit "$f" 2>&1 >/dev/null | sed -n 's/.* is in \(.*\)$/\1/p')
rm -rf $D/pkg; cp -R "$out" $D/pkg; cp $D/runtime_patched.zig $D/pkg/rig/runtime.zig
cd $D/pkg && zig run -O$mode __rig_main.zig 2>&1 | head -30
