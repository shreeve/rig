// 9. Which vector operations are safety-checked in ReleaseSafe?
// Run: safety <case>; a checked case panics, an unchecked one prints a value.
const std = @import("std");
const V = @Vector(4, u8);
const VI = @Vector(4, i8);

var sink: [64]u8 = undefined;
fn rt(comptime T: type, x: T) T {
    // Launder through memory so values are runtime-known.
    var y: T = x;
    _ = &y;
    return @as(*volatile T, &y).*;
}
fn show(v: anytype) void {
    std.debug.print("value: {any}\n", .{v});
}

pub fn main(init: std.process.Init.Minimal) void {
    const args = init.args.vector;
    const c = std.mem.sliceTo(args[1], 0);
    const a = rt(V, .{ 1, 2, 3, 250 });
    const b = rt(V, .{ 1, 1, 1, 10 });
    if (std.mem.eql(u8, c, "add")) show(a + b); // lane 3 overflows
    if (std.mem.eql(u8, c, "sub")) show(b - a); // lanes 1..3 underflow
    if (std.mem.eql(u8, c, "mul")) show(a * b); // lane 3 overflows
    if (std.mem.eql(u8, c, "neg")) show(-rt(VI, .{ 0, 1, -128, 3 }));
    if (std.mem.eql(u8, c, "div0")) show(a / rt(V, .{ 1, 0, 1, 1 }));
    if (std.mem.eql(u8, c, "divexact")) show(@divExact(a, rt(V, .{ 1, 2, 1, 1 })));
    if (std.mem.eql(u8, c, "intcast")) show(@as(V, @intCast(rt(@Vector(4, u16), .{ 1, 2, 300, 4 }))));
    if (std.mem.eql(u8, c, "intcast_shift")) {
        const s: @Vector(4, u3) = @intCast(rt(V, .{ 1, 2, 9, 4 })); // 9 does not fit u3
        show(a >> s);
    }
    if (std.mem.eql(u8, c, "truncate")) show(@as(V, @truncate(rt(@Vector(4, u16), .{ 1, 2, 300, 4 }))));
    if (std.mem.eql(u8, c, "shl")) show(a << @splat(1)); // 250 << 1 drops a bit: unchecked
    if (std.mem.eql(u8, c, "shlexact")) show(@shlExact(a, @as(@Vector(4, u3), @splat(1))));
    if (std.mem.eql(u8, c, "shrexact")) show(@shrExact(a, @as(@Vector(4, u3), @splat(1))));
    if (std.mem.eql(u8, c, "floatint")) show(@as(V, @intFromFloat(rt(@Vector(4, f32), .{ 1, 2, 300, 4 }))));
    if (std.mem.eql(u8, c, "reduce_add")) show(@reduce(.Add, a)); // wraps by definition
    if (std.mem.eql(u8, c, "index")) {
        const t: [4]u8 = .{ 9, 8, 7, 6 };
        show(t[a[3]]); // 250 out of bounds
    }
    if (std.mem.eql(u8, c, "lane_rt")) {
        const arr: [4]u8 = a; // runtime lane index needs an array
        show(arr[rt(usize, 7)]);
    }
    if (std.mem.eql(u8, c, "slice_load")) {
        const buf: []const u8 = sink[0..rt(usize, 20)];
        const v: @Vector(16, u8) = buf[rt(usize, 8)..][0..16].*;
        show(v);
    }
    if (std.mem.eql(u8, c, "bool_bitcast")) {
        const m: @Vector(8, bool) = @bitCast(rt(u8, 0xA5));
        show(m);
    }
    // (vectors of enums are a compile error: element must be int, float, bool or pointer)
}
