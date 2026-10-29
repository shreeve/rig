#!/bin/bash
# mk3.sh NAME ORDERED.zig [NOPS]: the bench package (PKG, default main) with rig/ordered.zig replaced and
# NOPS nops added to placePast, a cold function each Map type's code places among the program's, as NAME.bin
set -e
cd "$(dirname "$0")"
rm -rf $1 && cp -r ${PKG:-main} $1 && cp $2 $1/rig/ordered.zig
if [ -n "${3:-}" ]; then python3 - $1/rig/ordered.zig $3 <<'PY'
import sys
p,n=sys.argv[1],int(sys.argv[2])
s=open(p).read()
old="""        noinline fn placePast(self: *Self, g: usize, tag: u8, j: usize) void {
            @branchHint(.unlikely);"""
assert s.count(old)==1
s=s.replace(old, old+'\n            asm volatile ("'+'nop\\n'*n+'");')
open(p,'w').write(s)
PY
fi
cd $1 && zig build-exe -Ofast -fomit-frame-pointer --dep rig -Mroot=__rig_main.zig -Mrig=rig/runtime.zig -femit-bin=../$1.bin
