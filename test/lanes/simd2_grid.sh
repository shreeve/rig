#!/usr/bin/env bash
# Builds test/lanes/simd2_grid.zig for each CPU named (the host's own by
# default: `native`; on x86 also `x86_64` with no SSSE3, `x86_64_v2`
# without AVX2, `x86_64_v3` with it) in Debug, ReleaseSafe, and
# ReleaseFast, runs it, and checks that `vecShl` panics where a lane loses
# a bit. With WASM=1 it also runs WASM, with and without SIMD, under
# wasmtime (WASM SIMD in the optimized modes only: at -O0, LLVM shifts a
# vector by an amount narrower than a byte wrong, e.g. `<16 x i8>` by
# `<16 x i3>`, which no Rig target builds). Exits 1 if any build or cell
# fails.
#
#   test/lanes/simd2_grid.sh [cpu...]
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$(dirname "$here")")
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
zig=${ZIG:-zig}
seeds=${SEEDS:-100}
status=0
targets=()
for cpu in "${@:-native}"; do targets+=("native:$cpu"); done
[ "${WASM:-0}" = 1 ] && targets+=("wasm32-wasi:generic" "wasm32-wasi:generic+simd128")
for t in "${targets[@]}"; do
    target=${t%%:*}; cpu=${t#*:}
    for mode in Debug ReleaseSafe ReleaseFast; do
        [ "$cpu" = generic+simd128 ] && [ "$mode" = Debug ] && continue
        exe=$out/grid-$target-$cpu-$mode
        [ "$target" = wasm32-wasi ] && exe=$exe.wasm
        if ! "$zig" build-exe -target "$target" -mcpu="$cpu" -O "$mode" -femit-bin="$exe" --cache-dir "$out/cache" \
            --dep rig -Mroot="$here/simd2_grid.zig" -Mrig="$root/src/runtime.zig" 2>"$out/err"; then
            echo "$target $cpu $mode: build failed"; head -20 "$out/err"; status=1; continue
        fi
        run=("$exe"); [ "$target" = wasm32-wasi ] && run=(wasmtime "$exe")
        printf '%s %s %s: ' "$target" "$cpu" "$mode"
        "${run[@]}" "$seeds" >"$out/o" 2>&1; rc=$?
        tail -40 "$out/o"; [ $rc = 0 ] || status=1
        [ "$mode" = ReleaseFast ] && continue
        # (The shell's "Abort trap" notes for the expected panics are dropped.)
        for ty in u8 i8 u16 i64; do for n in 2 16 32 64; do
            if "${run[@]}" shl "$ty" "$n" >"$out/o" 2>&1 || ! grep -q "left shift overflowed bits" "$out/o"; then
                echo "  vecShl $ty x$n: no panic"; status=1
            fi
        done; done 2>/dev/null
    done
done
exit $status
