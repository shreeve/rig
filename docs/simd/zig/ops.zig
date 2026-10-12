const std = @import("std");
pub fn main() void {
    var a: @Vector(16, u8) = "ab\"d\\fghijklmnop".*;
    _ = &a;
    const q: @Vector(16, u8) = @splat('"');
    const m = a == q;
    const bits: u16 = @bitCast(m);
    std.debug.print("bits={b:0>16} ctz={d}\n", .{ bits, @ctz(bits) });
    const any = @reduce(.Or, m);
    const sum = @reduce(.Add, @as(@Vector(16, u16), a));
    const sel = @select(u8, m, @as(@Vector(16, u8), @splat(0)), a);
    const sh: @Vector(16, u8) = a >> @splat(4);
    const shl = @shlExact(@as(@Vector(4,u8), .{1,2,3,4}), @as(@Vector(4,u3), @splat(2)));
    const shuf = @shuffle(u8, a, undefined, @Vector(4, i32){ 3, 2, 1, 0 });
    const wrap = a +% @as(@Vector(16, u8), @splat(200));
    const arr: [16]u8 = sel;
    const mn = @min(a, q);
    std.debug.print("any={} sum={d} sel={s} sh0={d} shl={any} shuf={any} wrap0={d} mn0={d}\n", .{ any, sum, &arr, sh[0], @as([4]u8, shl), @as([4]u8, shuf), wrap[0], mn[0] });
    // mask ops
    const m2 = a < @as(@Vector(16, u8), @splat(0x20));
    const both = m | m2; // bool vector or?
    std.debug.print("both={b}\n", .{@as(u16, @bitCast(both))});
}
