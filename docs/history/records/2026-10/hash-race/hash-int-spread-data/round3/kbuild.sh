#!/bin/bash
# kbuild.sh MUL...: knucleotide-fast with and without mix, each multiplier, as kn-{mix,nomix}-MUL.bin
cd "$(dirname "$0")"
for m in "$@"; do for v in mix nomix; do
  [ -x kn-$v-$m.bin ] && continue
  d=b-$v-$m; rm -rf $d && cp -r pkg-$v $d
  python3 - $d/rig/unordered.zig $m <<'PY'
import sys,re
p,m=sys.argv[1],sys.argv[2]; s=open(p).read()
s,k=re.subn(r"const int_mul: u64 = 0x[0-9a-f]+;", "const int_mul: u64 = %s;"%m, s); assert k==1
open(p,'w').write(s)
PY
  (cd $d && zig build-exe -Ofast -fomit-frame-pointer --dep rig -Mroot=__rig_main.zig -Mrig=rig/runtime.zig -femit-bin=../kn-$v-$m.bin 2>&1 | tail -3) && rm -rf $d || echo FAIL $v $m
done; done
