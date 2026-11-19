#!/bin/bash
# bcbuild.sh PKG OUT [FLAG...]: build the emitted package PKG as
# relink.sh does, but through LLVM bitcode: Zig writes the optimized module
# (-femit-llvm-bc), `zig cc` compiles it to an object with the IR passes
# off and each FLAG given to clang (for example -falign-loops=64,
# which Zig 0.17 does not pass), then the program section is kept apart
# and Zig links. Run it under tools/heavy.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
P=$1; OUT=$2; shift 2
F=(-Osafe -fomit-frame-pointer -fno-stack-protector -mcpu=native+reserve_x15)
zig build-obj "${F[@]}" --cache-dir "$P/.zig-cache" "$P/__rig_main.zig" -fno-emit-bin -femit-llvm-bc="$P/p.bc" -lc
M=("$@")
zig cc -c -O3 -Xclang -disable-llvm-optzns ${M[@]+"${M[@]}"} "$P/p.bc" -o "$P/p.o"
python3 "$here/apart.py" "$P/p.o" "$P/p-apart.o"
zig build-exe "${F[@]}" --cache-dir "$P/.zig-cache" "$P/p-apart.o" -lc -femit-bin="$OUT"
