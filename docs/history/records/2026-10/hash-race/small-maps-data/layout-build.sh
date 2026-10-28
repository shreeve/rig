#!/bin/bash
# mk.sh NAME ORDERED.zig [EXTRA_NOPS]: the bench package with rig/ordered.zig replaced, built as NAME.bin
set -e
cd /private/tmp/claude-501/sm/pkg
rm -rf $1 && cp -r main $1 && cp $2 $1/rig/ordered.zig
if [ -n "${3:-}" ]; then python3 - $1/rig/ordered.zig $3 <<'PY'
import sys
p,n=sys.argv[1],int(sys.argv[2])
s=open(p).read()
old="""        noinline fn tooMany() noreturn {
            @branchHint(.cold);"""
assert s.count(old)==1
s=s.replace(old, old+'\n            asm volatile ("'+'nop\\n'*n+'");')
open(p,'w').write(s)
PY
fi
cd $1 && zig build-exe -Ofast -fomit-frame-pointer --dep rig -Mroot=__rig_main.zig -Mrig=rig/runtime.zig -femit-bin=../$1.bin
