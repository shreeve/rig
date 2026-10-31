//! Writes std/crypto/x25519/table.rig, the table of std.crypto.x25519's
//! fixed-base comb: for j in 0..32 and k in 1..9, k·256^j·B on
//! edwards25519, B the base point (whose Montgomery u is 9), as the
//! affine triple (y + x, y - x, 2dxy), each a field element of five
//! canonical 51-bit limbs, padded with a zero to 16 limbs (128 bytes).
//! Run from the repository's root: `zig run tools/x25519-table.zig`.
const std = @import("std");
const Ed = std.crypto.ecc.Edwards25519;
const Fe = Ed.Fe;

fn canon(a: Fe) Fe {
    return Fe.fromBytes(a.toBytes());
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var out: std.Io.Writer.Allocating = .init(init.gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll(
        \\# std.crypto.x25519: the fixed-base comb's table, written by
        \\# tools/x25519-table.zig. Entry (j, k) is k·256^j·B on edwards25519
        \\# for j in 0..32 and k in 1..9, B the base point, as (y + x, y - x,
        \\# 2dxy) in canonical 51-bit limbs and a zero: 16 limbs, 128 bytes, at
        \\# (j*8 + k - 1)*16.
        \\
        \\BASE: [4096]U64 = [
        \\
    );
    var pj = Ed.basePoint;
    for (0..32) |_| {
        var acc = pj;
        for (0..8) |_| {
            const zi = acc.z.invert();
            const x = acc.x.mul(zi);
            const y = acc.y.mul(zi);
            const e = [3]Fe{ canon(y.add(x)), canon(y.sub(x)), canon(x.mul(y).mul(Fe.edwards25519d2)) };
            try w.writeAll(" ");
            for (e) |fe| for (fe.limbs) |l| try w.print(" {d},", .{l});
            try w.writeAll(" 0,\n");
            acc = acc.add(pj);
        }
        for (0..8) |_| pj = pj.dbl();
    }
    try w.writeAll("]\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "std/crypto/x25519/table.rig", .data = out.written() });
}
