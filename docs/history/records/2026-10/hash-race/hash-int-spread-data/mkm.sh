#!/bin/bash
# mkm.sh MUL [NOPS]: the probe package with int_mul = MUL (and NOPS nops in claimGrown), as p-MUL-NOPS.bin
set -e
cd "$(dirname "$0")"
m=$1; n=${2:-0}; d=b-$m-$n; rm -rf $d && cp -r pkg $d
python3 - $d/rig/unordered.zig $m $n <<'PY'
import sys,re
p,m,n=sys.argv[1],sys.argv[2],int(sys.argv[3]); s=open(p).read()
s,k=re.subn(r"const int_mul: u64 = 0x[0-9a-f]+;", "const int_mul: u64 = %s;"%m, s); assert k==1
old="        noinline fn claimGrown(self: *Self, hash: u64) usize {"
assert s.count(old)==1
if n: s=s.replace(old, old+'\n            asm volatile ("'+'nop\\n'*n+'");')
open(p,'w').write(s)
PY
cd $d && zig build-exe -Ofast -fomit-frame-pointer --dep rig -Mroot=__rig_main.zig -Mrig=rig/runtime.zig -femit-bin=../p-$m-$n.bin 2>&1 | tail -3
