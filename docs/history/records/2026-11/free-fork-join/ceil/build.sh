#!/bin/bash
# build.sh OUT: build every arm of the ceiling into OUT (one binary an arm,
# 1-pass and 3-pass), with the flags `rig build --release` gives Zig:
# -Osafe, no frame pointers, no stack canaries, the native CPU (plus x15
# reserved on arm64, as Rig's).
set -euo pipefail
cd "$(dirname "$0")"
OUT=${1:?usage: build.sh OUT}
mkdir -p "$OUT"
case $(uname -m) in
arm64|aarch64) CPU=native+reserve_x15 ;;
*) CPU=native ;;
esac
arm() { # NAME CFG
    for p in 1 3; do
        n=$1; [[ $p == 3 ]] && n=${1}3
        printf 'pub const cfg: @import("ceil.zig").Cfg = .{ %s.passes = %d };\npub const main = @import("ceil.zig").main;\n' "$2" "$p" >"arm_$n.zig"
        "${ZIG:-zig}" build-exe -Osafe -fomit-frame-pointer -fno-stack-protector -mcpu=$CPU -lc \
            --cache-dir "$OUT/.zig-cache" -femit-bin="$OUT/$n" "arm_$n.zig"
    done
}
arm ceil ''
arm heap '.heap = true, '
arm stack '.stack = true, '
arm sc '.sc = true, '
arm mon '.monitor = true, '
arm all4 '.heap = true, .stack = true, .sc = true, .monitor = true, '
arm seq '.seq = true, '
arm off '.offmain = true, '
cp "$OUT/ceil" "$OUT/ceil-aa"
cp "$OUT/ceil3" "$OUT/ceil3-aa"
