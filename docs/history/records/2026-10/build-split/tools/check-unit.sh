#!/bin/sh
# check-unit.sh DIR: Sema-check one unit (no code), low priority.
cd "$1" && /Users/shreeve/Data/Code/rig/tools/low zig build-obj -OReleaseSafe -fomit-frame-pointer -fno-emit-bin --cache-dir .zig-cache __rig_unit_root.zig 2>&1
