pub export fn special64(p: [*]const u8) u64 {
    const v: @Vector(64, u8) = p[0..64].*;
    const m = (v == @as(@Vector(64, u8), @splat('"'))) | (v == @as(@Vector(64, u8), @splat('\\'))) | (v < @as(@Vector(64, u8), @splat(0x20)));
    return @bitCast(m);
}
export fn special16(p: [*]const u8) u16 {
    const v: @Vector(16, u8) = p[0..16].*;
    const m = (v == @as(@Vector(16, u8), @splat('"'))) | (v == @as(@Vector(16, u8), @splat('\\'))) | (v < @as(@Vector(16, u8), @splat(0x20)));
    return @bitCast(m);
}
export fn any16(p: [*]const u8) bool {
    const v: @Vector(16, u8) = p[0..16].*;
    const m = (v == @as(@Vector(16, u8), @splat('"'))) | (v == @as(@Vector(16, u8), @splat('\\'))) | (v < @as(@Vector(16, u8), @splat(0x20)));
    return @reduce(.Or, m);
}
