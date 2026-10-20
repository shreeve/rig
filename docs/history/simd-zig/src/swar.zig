// SWAR single-block kernels, for instruction counts against bitmask.zig.
const std = @import("std");
const Q: u8 = '"';
inline fn swarHi(comptime T: type, w: T) T {
    const lo7: T = @as(T, ~@as(T, 0)) / 0xFF * 0x7F;
    const x = w ^ (@as(T, ~@as(T, 0)) / 0xFF * Q);
    const t = (x & lo7) +% lo7;
    return ~(t | x | lo7);
}
inline fn compress8(h: u64) u8 {
    return @truncate(((h >> 7) *% 0x0102040810204080) >> 56);
}
// 8 bytes -> 8-bit mask
export fn swar8(p: *const [8]u8) u8 {
    return compress8(swarHi(u64, std.mem.readInt(u64, p, .little)));
}
// 64 bytes -> linear u64 mask
export fn swar64_block(p: *const [64]u8) u64 {
    var m: u64 = 0;
    inline for (0..8) |k| m |= @as(u64, compress8(swarHi(u64, std.mem.readInt(u64, p[k * 8 ..][0..8], .little)))) << (k * 8);
    return m;
}
// 8 bytes: first match index via the 0x80 mask (no compress); 8 if none
export fn swar8_first(p: *const [8]u8) u32 {
    return @ctz(swarHi(u64, std.mem.readInt(u64, p, .little))) >> 3;
}
// 16 bytes as u128: first match index; 16 if none
export fn swar16_first(p: *const [16]u8) u32 {
    return @ctz(swarHi(u128, std.mem.readInt(u128, p, .little))) >> 3;
}
// u128 loaded by @bitCast instead of std.mem.readInt (little-endian targets)
export fn swar16_first_bc(p: *const [16]u8) u32 {
    const w: u128 = @bitCast(p.*);
    return @ctz(swarHi(u128, w)) >> 3;
}
export fn readint_u128(p: *const [16]u8) u128 {
    return std.mem.readInt(u128, p, .little);
}
