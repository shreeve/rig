inline fn sp16(v: @Vector(16, u8)) u16 {
    const m = (v == @as(@Vector(16, u8), @splat('"'))) | (v == @as(@Vector(16, u8), @splat('\\'))) | (v < @as(@Vector(16, u8), @splat(0x20)));
    return @bitCast(m);
}
export fn special64x4(p: [*]const u8) u64 {
    var r: u64 = 0;
    inline for (0..4) |k| {
        const v: @Vector(16, u8) = p[k * 16 ..][0..16].*;
        r |= @as(u64, sp16(v)) << (k * 16);
    }
    return r;
}
// generic: bits of a 64-lane bool vector, by 16-lane pieces
fn bits64(m: @Vector(64, bool)) u64 {
    const a: [64]bool = m;
    var r: u64 = 0;
    inline for (0..4) |k| {
        const piece: @Vector(16, bool) = a[k * 16 ..][0..16].*;
        r |= @as(u64, @as(u16, @bitCast(piece))) << (k * 16);
    }
    return r;
}
export fn special64split(p: [*]const u8) u64 {
    const v: @Vector(64, u8) = p[0..64].*;
    const m = (v == @as(@Vector(64, u8), @splat('"'))) | (v == @as(@Vector(64, u8), @splat('\\'))) | (v < @as(@Vector(64, u8), @splat(0x20)));
    return bits64(m);
}
