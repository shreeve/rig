//! std.terminal's Zig shim. A run of printable bytes becomes cells sixteen
//! at a time, written with `@Vector`: Zig 0.17 turns LLVM's loop
//! vectorizer off (docs/internals/zig-0.17.md §16), so the same loop in
//! Rig, or in plain Zig, runs a cell at a time, a third as fast. On Zig
//! 0.18, whose LLVM vectorizes loops again, `widen` moves back into
//! std/terminal.rig as a plain loop and this file goes (docs/ROADMAP.md).

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
