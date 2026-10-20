//! std.terminal's cell writes in Zig, where a vector can be widened and
//! stored: a run of printable bytes becomes cells sixteen at a time.

/// `dst[i] = src[i] | bits` for each `i` of the shorter of the two: each
/// byte a rune in the low bits of its cell, with the style bits above.
pub fn widen(dst: []u64, src: []const u8, bits: u64) void {
    const n = @min(dst.len, src.len);
    const lanes = 16;
    const style: @Vector(lanes, u64) = @splat(bits);
    var i: usize = 0;
    while (i + lanes <= n) : (i += lanes) {
        const bytes: @Vector(lanes, u8) = src[i..][0..lanes].*;
        const runes: @Vector(lanes, u64) = bytes;
        dst[i..][0..lanes].* = runes | style;
    }
    while (i < n) : (i += 1) dst[i] = @as(u64, src[i]) | bits;
}
