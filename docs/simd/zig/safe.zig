const std = @import("std");
var sink: u64 = 0;
fn t(comptime name: []const u8, comptime f: fn () void) void { _ = name; f(); }
pub fn main(init: std.process.Init.Minimal) void {
    const which = std.mem.sliceTo(init.args.vector[1], 0);
    var a: @Vector(4, u8) = .{ 1, 2, 0x80, 4 };
    var k: u8 = 9;
    _ = &a; _ = &k;
    if (std.mem.eql(u8, which, "shl")) {
        const r = @shlExact(a, @as(@Vector(4, u3), @splat(1)));
        std.debug.print("{any}\n", .{@as([4]u8, r)});
    } else if (std.mem.eql(u8, which, "amt")) {
        const amt: @Vector(4, u3) = @intCast(@as(@Vector(4, u8), @splat(k)));
        std.debug.print("{any}\n", .{@as([4]u8, a >> amt)});
    } else if (std.mem.eql(u8, which, "reduce")) {
        const b: @Vector(4, u8) = .{ 200, 100, 1, 1 };
        std.debug.print("{d}\n", .{@reduce(.Add, b +% a -% a)});
    } else if (std.mem.eql(u8, which, "not")) {
        const m = a > @as(@Vector(4, u8), @splat(2));
        const n = !m;
        std.debug.print("{any}\n", .{@as([4]bool, n)});
    } else if (std.mem.eql(u8, which, "conv")) {
        var w: @Vector(4, u16) = .{ 1, 300, 3, 4 }; _ = &w;
        const n: @Vector(4, u8) = @intCast(w);
        std.debug.print("{any}\n", .{@as([4]u8, n)});
    } else if (std.mem.eql(u8, which, "div")) {
        var z: @Vector(4, u8) = .{ 1, 0, 1, 1 }; _ = &z;
        std.debug.print("{any}\n", .{@as([4]u8, a / z)});
    }
}
