// Wide bool vectors on wasm: which forms scalarize?
const V16 = @Vector(16, u8);
const V32 = @Vector(32, u8);
const V64 = @Vector(64, u8);
export fn any32(a: *const V32) bool { return @reduce(.Or, a.* == @as(V32, @splat('"'))); }
export fn any64(a: *const V64) bool { return @reduce(.Or, a.* == @as(V64, @splat('"'))); }
export fn all64(a: *const V64) bool { return @reduce(.And, a.* == @as(V64, @splat('"'))); }
// 64-lane compare kept as bytes (select to 0xFF/0), OR-reduced to 16, then any.
export fn any64_bytes(a: *const V64) bool {
    const m = @select(u8, a.* == @as(V64, @splat('"')), @as(V64, @splat(0xFF)), @as(V64, @splat(0)));
    const arr: [4]V16 = @bitCast(m);
    return @reduce(.Or, (arr[0] | arr[1] | arr[2] | arr[3]) != @as(V16, @splat(0)));
}
// 64-lane bitmask built from four 16-lane bitcasts of a 64-byte compare.
export fn bm64_split(a: *const V64) u64 {
    const arr: [4]V16 = @bitCast(a.*);
    var m: u64 = 0;
    inline for (0..4) |k| {
        const b: u16 = @bitCast(arr[k] == @as(V16, @splat('"')));
        m |= @as(u64, b) << (k * 16);
    }
    return m;
}
// 64-lane add / select (no bool reduction): split fine?
export fn sel64(a: *const V64, b: *const V64, o: *V64) void { o.* = @select(u8, a.* < b.*, a.*, b.*); }
