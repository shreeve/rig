#!/bin/bash
# looppad.sh SRC DST N: copy the emitted package SRC to DST with
# `asm volatile (".p2align N")` just before qsort's partition loop, the one
# loop-head padding Zig allows by hand (LLVM has no -align-loops in Zig 0.17).
set -euo pipefail
S=$1; D=$2; N=$3
rm -rf "$D"; mkdir -p "$D"
(cd "$S" && find . -name '*.zig' -not -path './.zig-cache/*' | cpio -pdm --quiet "$D")
perl -0pi -e "s/(\\n(\\s*)var __rig_turns_9: u32 = rig.tick_turns;\\n)/\\n\$2asm volatile (\".p2align $N\");\$1/" "$D/__rig_main.zig"
grep -q 'p2align' "$D/__rig_main.zig"
