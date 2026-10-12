const std = @import("std");
const V = @Vector(16, u8);
const r = blk: {
    const v: V = "abc\"def\\ghi\"jk!!".*;
    const q = v == @as(V, @splat(34));
    const m: u16 = @bitCast(q);
    const s = @select(u8, q, v, @as(V, @splat(0)));
    const sat = v +| @as(V, @splat(200));
    const sh = v >> @splat(4);
    const ba: [16]bool = q;
    break :blk .{ m, @reduce(.Add, s), @reduce(.Min, sat), @reduce(.Max, sh), std.simd.firstTrue(q).?, @shuffle(u8, v, undefined, [2]i32{ 3, 0 }), @as(u16, @bitCast(ba)), @popCount(v)[0] };
};
comptime {
    @compileLog(r);
}
