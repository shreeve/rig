const V = @Vector(16, u8);
fn evens(comptime n: usize) @Vector(n, i32) { var r: [n]i32 = undefined; for (0..n) |i| r[i] = @intCast(2 * i); return r; }
fn odds(comptime n: usize) @Vector(n, i32) { var r: [n]i32 = undefined; for (0..n) |i| r[i] = @intCast(2 * i + 1); return r; }
// pairwise add of a ++ b  (NEON addp)
inline fn addp(a: V, b: V) V {
    return @shuffle(u8, a, b, evensCat()) +% @shuffle(u8, a, b, oddsCat());
}
fn evensCat() @Vector(16, i32) { var r: [16]i32 = undefined; for (0..16) |i| { const j = 2*i; r[i] = if (j < 16) @intCast(j) else ~@as(i32, @intCast(j - 16)); } return r; }
fn oddsCat() @Vector(16, i32) { var r: [16]i32 = undefined; for (0..16) |i| { const j = 2*i+1; r[i] = if (j < 16) @intCast(j) else ~@as(i32, @intCast(j - 16)); } return r; }
inline fn bits4(m0: @Vector(16,bool), m1: @Vector(16,bool), m2: @Vector(16,bool), m3: @Vector(16,bool)) u64 {
    const w: V = .{ 1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128 };
    const z: V = @splat(0);
    const a = @select(u8, m0, w, z);
    const b = @select(u8, m1, w, z);
    const c = @select(u8, m2, w, z);
    const d = @select(u8, m3, w, z);
    const s1 = addp(a, b);
    const s2 = addp(c, d);
    const s3 = addp(s1, s2);
    const s4 = addp(s3, s3);
    const arr: [16]u8 = s4;
    return @bitCast(arr[0..8].*);
}
inline fn sp(v: V) @Vector(16, bool) {
    return (v == @as(V, @splat('"'))) | (v == @as(V, @splat('\\'))) | (v < @as(V, @splat(0x20)));
}
export fn special64p(p: [*]const u8) u64 {
    const a: V = p[0..16].*; const b: V = p[16..32].*; const c: V = p[32..48].*; const d: V = p[48..64].*;
    return bits4(sp(a), sp(b), sp(c), sp(d));
}
