const std = @import("std");
fn rt(comptime T: type, x: T) T { var y: T = x; _ = &y; return @as(*volatile T, &y).*; }
pub fn main(init: std.process.Init.Minimal) void {
    const c = std.mem.sliceTo(init.args.vector[1], 0);
    if (std.mem.eql(u8, c, "vdivexact")) std.debug.print("{any}\n", .{@divExact(rt(@Vector(4, u8), .{ 1, 2, 3, 4 }), rt(@Vector(4, u8), .{ 1, 2, 2, 1 }))});
    if (std.mem.eql(u8, c, "sdivexact")) std.debug.print("{any}\n", .{@divExact(rt(u8, 3), rt(u8, 2))});
    if (std.mem.eql(u8, c, "vshrexact")) std.debug.print("{any}\n", .{@shrExact(rt(@Vector(4, u8), .{ 1, 2, 3, 4 }), @as(@Vector(4, u3), @splat(1)))});
    if (std.mem.eql(u8, c, "sshrexact")) std.debug.print("{any}\n", .{@shrExact(rt(u8, 3), 1)});
    if (std.mem.eql(u8, c, "vshlexact_lane3")) std.debug.print("{any}\n", .{@shlExact(rt(@Vector(4, u8), .{ 1, 2, 3, 200 }), @as(@Vector(4, u3), @splat(1)))});
    if (std.mem.eql(u8, c, "vrem0")) std.debug.print("{any}\n", .{@rem(rt(@Vector(4, u8), .{ 1, 2, 3, 4 }), rt(@Vector(4, u8), .{ 1, 0, 2, 1 }))});
    if (std.mem.eql(u8, c, "vdivtrunc_min")) std.debug.print("{any}\n", .{@divTrunc(rt(@Vector(4, i8), .{ 1, -128, 3, 4 }), rt(@Vector(4, i8), .{ 1, -1, 2, 1 }))});
}
