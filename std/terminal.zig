//! std.terminal's Zig shim: what it needs that Rig cannot yet say. A run
//! of printable bytes becomes cells sixteen at a time, which takes a
//! widening vector conversion (u8 lanes to u64) and a vector store into a
//! slice of U64; Rig has neither, and LLVM leaves the plain loop scalar.
//! When Rig gains both (docs/ROADMAP.md, Speed), `widen` moves back into
//! std/terminal.rig and this file goes.

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
