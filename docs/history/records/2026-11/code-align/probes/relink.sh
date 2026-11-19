#!/bin/bash
# relink.sh PKG OUT: build an emitted package PKG (a RIG_OUT_DIR of a
# preempted release build, its Zig edited by hand) as `rig build
# --release` does on arm64 macOS: build-obj with x15 reserved, the
# program section kept apart (apart.py), build-exe. Run it under tools/heavy.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
P=$1; OUT=$2
F=(-Osafe -fomit-frame-pointer -fno-stack-protector -mcpu=native+reserve_x15)
zig build-obj "${F[@]}" --cache-dir "$P/.zig-cache" "$P/__rig_main.zig" -femit-bin="$P/p.o" -lc
python3 "$here/apart.py" "$P/p.o" "$P/p-apart.o"
zig build-exe "${F[@]}" --cache-dir "$P/.zig-cache" "$P/p-apart.o" -lc -femit-bin="$OUT"
