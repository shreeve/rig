#!/bin/bash
# addr.sh SRCPKG NAME ORDERED: a copy of SRCPKG printing each churn_turns and int_edit_put_pass Map's address mod 64 and its table's entries/len offsets.
set -e
cd "$(dirname "$0")"
rm -rf $2 && cp -r $1 $2 && cp $3 $2/rig/ordered.zig
python3 - $2/__rig_main.zig <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
for f in ("pub noinline fn churn_turns(m: *__rig_m2_std_prelude.Map(i64, i64), ks: *const rig.List(i64), s: i64, turns: i64) Row {","pub noinline fn int_edit_put_pass(m: *__rig_m2_std_prelude.Map(i64, i64), n: i64) i64 {"):
    assert s.count(f)==1
    name=f.split("fn ")[1].split("(")[0]
    s=s.replace(f, f+'\n    @import("std").debug.print("ADDR '+name+' {d} t@{d} size {d}\\n", .{ @intFromPtr(m) % 64, @offsetOf(@TypeOf(m.*), "t"), @sizeOf(@TypeOf(m.*)) });')
open(p,'w').write(s)
PY
cd $2 && zig build-exe -Ofast -fomit-frame-pointer --dep rig -Mroot=__rig_main.zig -Mrig=rig/runtime.zig -femit-bin=../$2.bin
