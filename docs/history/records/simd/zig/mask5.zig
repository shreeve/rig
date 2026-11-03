fn idx(comptime k: usize) @Vector(16, i32) {
    var r: [16]i32 = undefined;
    for (0..16) |i| r[i] = @intCast(k * 16 + i);
    return r;
}
fn bits64(m: @Vector(64, bool)) u64 {
    var r: u64 = 0;
    inline for (0..4) |k| {
        const piece = @shuffle(bool, m, undefined, idx(k));
        r |= @as(u64, @as(u16, @bitCast(piece))) << (k * 16);
    }
    return r;
}
fn bits64u8(m: @Vector(64, bool)) u64 {
    // widen to u8 lanes (0/0xFF) then per 16-lane piece movemask-like
    const b: @Vector(64, u8) = @select(u8, m, @as(@Vector(64, u8), @splat(0xFF)), @as(@Vector(64, u8), @splat(0)));
    var r: u64 = 0;
    inline for (0..4) |k| {
        const piece = @shuffle(u8, b, undefined, idx(k));
        const pm = piece >= @as(@Vector(16, u8), @splat(0x80));
        r |= @as(u64, @as(u16, @bitCast(pm))) << (k * 16);
    }
    return r;
}
export fn sh(p: [*]const u8) u64 {
    const v: @Vector(64, u8) = p[0..64].*;
    const m = (v == @as(@Vector(64, u8), @splat('"'))) | (v == @as(@Vector(64, u8), @splat('\\'))) | (v < @as(@Vector(64, u8), @splat(0x20)));
    return bits64(m);
}
export fn sh8(p: [*]const u8) u64 {
    const v: @Vector(64, u8) = p[0..64].*;
    const m = (v == @as(@Vector(64, u8), @splat('"'))) | (v == @as(@Vector(64, u8), @splat('\\'))) | (v < @as(@Vector(64, u8), @splat(0x20)));
    return bits64u8(m);
}
