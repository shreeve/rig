"""Shared pieces of the patches: the helpers each lowering stands in for,
and a function replacer for the emitted json.zig.

Every helper picks the instruction by a comptime test of the target and
falls back to portable Zig elsewhere, as the Rig operation it stands for
would (docs/json/OPCODE-STUDY.md names the operation).
"""
import re

HELPERS = r'''
// ---- opcode-study helpers (bench/json/opcodes/patches/_common.py) ----
const OpV = @Vector(16, u8);
const op_builtin = @import("builtin");
const op_neon = op_builtin.cpu.arch == .aarch64 and op_builtin.zig_backend == .stage2_llvm;
const op_ssse3 = op_builtin.cpu.arch == .x86_64 and op_builtin.zig_backend == .stage2_llvm and
    std.Target.x86.featureSetHas(op_builtin.cpu.features, .ssse3);
extern fn @"llvm.aarch64.neon.tbl1"(OpV, OpV) OpV;
extern fn @"llvm.x86.ssse3.pshuf.b.128"(OpV, OpV) OpV;
/// `t.lookup(idx)`: lane i is t[idx[i]], or 0 when idx[i] >= 16.
/// NEON tbl; x86 pshufb, with the index's high bit set past 15; else lanes.
inline fn opLookup(t: OpV, idx: OpV) OpV {
    if (comptime op_neon) return @"llvm.aarch64.neon.tbl1"(t, idx);
    if (comptime op_ssse3) {
        const big = idx > @as(OpV, @splat(15));
        return @"llvm.x86.ssse3.pshuf.b.128"(t, idx | @select(u8, big, @as(OpV, @splat(0x80)), @as(OpV, @splat(0))));
    }
    const ta: [16]u8 = t;
    var r: OpV = undefined;
    inline for (0..16) |k| r[k] = if (idx[k] < 16) ta[idx[k]] else 0;
    return r;
}
/// The same lookup where every index is below 16 (a nibble): no fixup.
inline fn opLookupNib(t: OpV, idx: OpV) OpV {
    if (comptime op_neon) return @"llvm.aarch64.neon.tbl1"(t, idx);
    if (comptime op_ssse3) return @"llvm.x86.ssse3.pshuf.b.128"(t, idx);
    const ta: [16]u8 = t;
    var r: OpV = undefined;
    inline for (0..16) |k| r[k] = ta[idx[k] & 15];
    return r;
}
/// `a.join(b).shuffle(...)`: lane i is the byte `k` places before lane i
/// of `b`, taken from the end of `a` (NEON ext, x86 palignr).
inline fn opPrev(a: OpV, b: OpV, comptime k: usize) OpV {
    const idx = comptime blk: {
        var x: [16]i32 = undefined;
        for (&x, 0..) |*e, j| e.* = if (j < k) @as(i32, 16 - k + j) else ~@as(i32, @intCast(j - k));
        break :blk x;
    };
    return @shuffle(u8, a, b, idx);
}
'''


def add_helpers(s):
    if "opcode-study helpers" in s:
        return s
    anchor = 'const rig = @import("rig/runtime.zig");\n'
    assert s.count(anchor) == 1
    return s.replace(anchor, anchor + HELPERS)


def fn_span(s, name):
    """The span of the top-level or method function `name` in json.zig."""
    m = re.search(r"^( *)pub (?:inline )?fn %s\(" % re.escape(name), s, re.M)
    assert m, "no fn " + name
    indent = m.group(1)
    end = s.index("\n" + indent + "}\n", m.start()) + len(indent) + 3
    return m.start(), end


def replace_fn(s, name, new):
    a, b = fn_span(s, name)
    return s[:a] + new.strip("\n") + "\n" + s[b:]


def fn_text(s, name):
    a, b = fn_span(s, name)
    return s[a:b]
