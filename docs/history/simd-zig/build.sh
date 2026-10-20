#!/bin/sh
# Emit asm for every src/*.zig on every target, ReleaseSafe and ReleaseFast.
cd "$(dirname "$0")"
export ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache" ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-gcache"
TARGETS="a64:aarch64-macos:apple_m1 a64lin:aarch64-linux:generic x64v1:x86_64-linux:x86_64 x64v2:x86_64-linux:x86_64_v2 x64v3:x86_64-linux:x86_64_v3 wasm:wasm32-freestanding:generic wasmsimd:wasm32-freestanding:generic+simd128"
for f in ${FILES:-src/*.zig}; do
  b=$(basename $f .zig)
  for t in $TARGETS; do
    name=${t%%:*}; rest=${t#*:}; triple=${rest%%:*}; cpu=${rest#*:}
    for m in ReleaseSafe ReleaseFast; do
      mkdir -p out/$name/$m
      zig build-obj -target $triple -mcpu=$cpu -O$m -fstrip -fomit-frame-pointer \
        -femit-asm=out/$name/$m/$b.s -fno-emit-bin $f > out/$name/$m/$b.err 2>&1 \
        || echo "FAIL $name $m $b: $(head -c 300 out/$name/$m/$b.err)"
    done
  done
done
