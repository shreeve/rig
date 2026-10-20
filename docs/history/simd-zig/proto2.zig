// What `rig emit` would produce for the scan sample, with the runtime
// helpers inlined here (rig.simdRead, rig.simdReadPadded, rig.maskBits).
const std = @import("std");
const builtin = @import("builtin");

pub fn simdRead(comptime n: usize, comptime T: type, bytes: []const u8, offset: i64) @Vector(n, T) {
    const size = n * @sizeOf(T);
    const i = std.math.cast(usize, offset) orelse @panic("byte read out of range");
    if (i > bytes.len or bytes.len - i < size) @panic("byte read out of range");
    const p: *align(1) const @Vector(n, T) = @ptrCast(bytes[i..][0..size]);
    return p.*;
}

pub fn simdReadPadded(comptime n: usize, bytes: []const u8, offset: i64, pad: u8) @Vector(n, u8) {
    const i = std.math.cast(usize, offset) orelse @panic("byte read out of range");
    if (i > bytes.len) @panic("byte read out of range");
    if (bytes.len - i >= n) return simdRead(n, u8, bytes, offset);
    var buf: [n]u8 = @splat(pad);
    @memcpy(buf[0 .. bytes.len - i], bytes[i..]);
    return buf;
}

fn MaskInt(comptime n: usize) type { return @Int(.unsigned, n); }

pub fn maskBits(comptime n: usize, m: @Vector(n, bool)) MaskInt(n) {
    if (comptime n == 64 and builtin.cpu.arch == .aarch64 and std.Target.aarch64.featureSetHas(builtin.cpu.features, .neon)) {
        const V = @Vector(16, u8);
        const addp = @extern(*const fn (V, V) callconv(.c) V, .{ .name = "llvm.aarch64.neon.addp.v16i8" });
        _ = addp;
    }
    if (comptime n > 16 and builtin.cpu.arch.isWasm()) {
        const b: @Vector(n, u8) = @select(u8, m, @as(@Vector(n, u8), @splat(0xFF)), @as(@Vector(n, u8), @splat(0)));
        const arr: [n]u8 = b;
        var r: MaskInt(n) = 0;
        inline for (0..n / 16) |k| {
            const piece: @Vector(16, u8) = arr[k * 16 ..][0..16].*;
            const pm = piece >= @as(@Vector(16, u8), @splat(0x80));
            r |= @as(MaskInt(n), @as(u16, @bitCast(pm))) << (k * 16);
        }
        return r;
    }
    return @bitCast(m);
}

// fun first_special(s: ?String, at: Int) -> Int
fn first_special(s: []const u8, at: i64) i64 {
    var i = at;
    while (i < @as(i64, @intCast(s.len))) {
        const v = simdReadPadded(64, s, i, 0x20);
        const m = (v == @as(@Vector(64, u8), @splat('"'))) | (v == @as(@Vector(64, u8), @splat('\\'))) | (v < @as(@Vector(64, u8), @splat(0x20))) | (v >= @as(@Vector(64, u8), @splat(0x80)));
        const bits = maskBits(64, m);
        if (bits != 0) return @min(i + @ctz(bits), @as(i64, @intCast(s.len)));
        i += 64;
    }
    return @intCast(s.len);
}

pub fn main() void {
    const t = "  key: \"va\\lue\" \x01 tail that runs on past sixty four bytes of plain ascii text";
    std.debug.print("{d} {d} {d} {d} {d} len={d}\n", .{ first_special(t, 0), first_special(t, 8), first_special(t, 11), first_special(t, 16), first_special(t, 18), t.len });
}
