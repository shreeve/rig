#!/bin/bash
# layout-build.sh ARM RIG: bench/hash's map.rig with its Map aliases made HashMap (bench-hash's
# rig-hash), built by RIG into the package pkg-ARM, then compiled in four layouts, ARM0 ARM5
# ARM13 ARM29.bin: 0, 5, 13 and 29 nops in claimGrown, a cold function each HashMap type's
# code places among the program's, compiled as rig build --release=fast compiles.
set -e
cd "$(dirname "$0")"
A=$1; R=$2; W=$HOME/Data/Code/worktrees/rig/hash-ensure
sed -E 's/^type ([A-Za-z0-9_]+) = Map\[/type \1 = HashMap[/' $W/bench/hash/map.rig > map-hash.rig
rm -rf pkg-$A && RIG_OUT_DIR=$PWD/pkg-$A $R build --release=fast -o $A.direct map-hash.rig
for n in 0 5 13 29; do
  rm -rf L-$A$n && mkdir L-$A$n && cp -R pkg-$A/*.zig pkg-$A/rig L-$A$n/
  python3 - L-$A$n/rig/unordered.zig $n <<'PY'
import sys
p, n = sys.argv[1], int(sys.argv[2])
s = open(p).read()
old = """        noinline fn claimGrown(self: *Self, hash: u64) usize {
"""
assert s.count(old) == 1
if n: s = s.replace(old, old + '            asm volatile ("' + 'nop\\n' * n + '");\n')
open(p, 'w').write(s)
PY
  (cd L-$A$n && zig build-exe -Ofast -fomit-frame-pointer --cache-dir ../zc-$A$n __rig_main.zig -femit-bin=../$A$n.bin)
done
