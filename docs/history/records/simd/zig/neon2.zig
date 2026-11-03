const V = @Vector(16, u8);
extern fn @"llvm.aarch64.neon.addp.v16i8"(V, V) V;
const addp = @"llvm.aarch64.neon.addp.v16i8";
inline fn sp(v: V) @Vector(16, bool) {
    return (v == @as(V, @splat('"'))) | (v == @as(V, @splat('\\'))) | (v < @as(V, @splat(0x20)));
}
pub export fn special64p(p: [*]const u8) u64 {
    const w: V = .{ 1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128 };
    const z: V = @splat(0);
    var s: [4]V = undefined;
    inline for (0..4) |k| { const v: V = p[k*16..][0..16].*; s[k] = @select(u8, sp(v), w, z); }
    const s1 = addp(s[0], s[1]);
    const s2 = addp(s[2], s[3]);
    const s3 = addp(s1, s2);
    const s4 = addp(s3, s3);
    const pair: @Vector(2, u64) = @bitCast(s4);
    return pair[0];
}
