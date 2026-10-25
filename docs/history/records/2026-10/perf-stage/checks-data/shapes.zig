// Prototypes: which emitted shapes let LLVM (ReleaseSafe) drop a check by itself.
// Build: zig build-obj -OReleaseSafe -target {aarch64-macos,x86_64-linux} -femit-asm=p.s p.zig
const std = @import("std");

const Rec = extern struct { kind: u16, flags: u16, pos: i32, end: i32, parent: u32, data: u32 };

// A Rig List: pointer, length, capacity.
const List = extern struct { ptr: [*]Rec, len: usize, cap: usize };
const Ast = extern struct { recs: List, words: List };

extern fn opaque_ro(a: *const Ast) void;
extern fn opaque_any() void;

inline fn at(l: *const List, i: u32) *const Rec {
    if (i >= l.len) @panic("index out of bounds");
    return &l.ptr[i];
}

// 1. Two accessor reads of one node around an opaque call (Trig: tree.pos(n) ... call ... tree.end(n)).
export fn two_reads_call(a: *const Ast, n: u32) i64 {
    const x = at(&a.recs, n).pos;
    opaque_ro(a);
    return @as(i64, x) + at(&a.recs, n).end;
}
// 1b. Snapshot the List as a slice once (a read view freezes it: Core 5, 6).
export fn two_reads_snapshot(a: *const Ast, n: u32) i64 {
    const recs = a.recs.ptr[0..a.recs.len];
    const x = recs[n].pos;
    opaque_ro(a);
    return @as(i64, x) + recs[n].end;
}
// 1c. noalias on the view parameter.
export fn two_reads_noalias(noalias a: *const Ast, n: u32) i64 {
    const x = at(&a.recs, n).pos;
    opaque_any();
    return @as(i64, x) + at(&a.recs, n).end;
}
// 1d. Two reads, no call between: LLVM's own CSE.
export fn two_reads_plain(a: *const Ast, n: u32) i64 {
    const x = at(&a.recs, n).pos;
    return @as(i64, x) + at(&a.recs, n).end;
}

// 2. Hash probe: home slot `h & (n - 1)` into a table of n slots, n a power of two.
export fn probe_mask(tags: [*]const u8, n: usize, h: u64) u8 {
    if (n == 0) return 0;
    const s = tags[0..n];
    return s[h & (n - 1)];
}
// 2b. The same with n read from the table, never tested non-zero first.
export fn probe_mask_nz(tags: [*]const u8, n: usize, h: u64) u8 {
    const s = tags[0..n];
    return s[h & (n -% 1)];
}
// 2c. A shift: the table holds 1 << b slots, the home is h >> (64 - b).
export fn probe_shift(tags: [*]const u8, b8: u8, h: u64) u8 {
    const b: u6 = @truncate(b8);
    const n = @as(usize, 1) << b;
    const s = tags[0..n];
    return s[(h >> (63 - b)) >> 1];
}
// 2d. A linear probe step: (i + 1) & mask after the home.
export fn probe_loop(tags: [*]const u8, n: usize, h: u64, want: u8) usize {
    if (n == 0) return 0;
    const s = tags[0..n];
    var i = h & (n - 1);
    while (true) {
        const t = s[i];
        if (t == want or t == 0) return i;
        i = (i + 1) & (n - 1);
    }
}

// 3. An affine loop: sum s[start + k] for k in 0..count (Trig: type lists as start, count spans).
export fn affine(s: [*]const u32, len: usize, start: u32, count: u32) u64 {
    const sl = s[0..len];
    var sum: u64 = 0;
    for (0..count) |k| sum += sl[start + k];
    return sum;
}
// 3b. Slice once, iterate the slice: one check before the loop (it fails earlier than 3 would).
export fn affine_slice(s: [*]const u32, len: usize, start: u32, count: u32) u64 {
    const sub = s[0..len][start..][0..count];
    var sum: u64 = 0;
    for (sub) |x| sum += x;
    return sum;
}
// 3c. A flag (Rig's form): one test into a constant, the checked loop where it is false.
export fn affine_flag(s: [*]const u32, len: usize, start: u32, count: u32) u64 {
    const sl = s[0..len];
    const ok = @as(u64, start) + count <= len;
    var sum: u64 = 0;
    if (ok) {
        const sub = sl.ptr[start..][0..count];
        for (sub) |x| sum += x;
    } else {
        for (0..count) |k| sum += sl[start + k];
    }
    return sum;
}

// 4. A guard on its false edge, then a call, then the index: LLVM reloads len after the call.
export fn guard_then_call(a: *const Ast, n: u32) i64 {
    if (n >= a.recs.len) return 0;
    opaque_ro(a);
    return at(&a.recs, n).pos;
}

// 5. A narrowing cast of a length that a type bounds (Table[T, 2^32]'s len held as u32 vs u64).
const T64 = extern struct { ptr: [*]u32, len: u64 };
const T32 = extern struct { ptr: [*]u32, len: u32 };
export fn len_cast64(t: *const T64) u32 {
    return @intCast(t.len);
}
export fn len_cast32(t: *const T32) u32 {
    return t.len;
}

// 6. A counter field += 1 under a capacity test (Map.insert's `@len += 1`).
const Counted = extern struct { len: i64, cap: i64 };
export fn bump(c: *Counted) void {
    if (c.len >= c.cap) return;
    c.len += 1;
}
export fn bump_free(c: *Counted) void {
    c.len += 1;
}

// 7. A two-level index: bindings[f].symbols[l] (Trig's symbol accessors before #187).
const Binding = extern struct { symbols: List };
export fn two_level(bs: [*]const Binding, nb: usize, f: u32, l: u32) i32 {
    const b = &bs[0..nb][f];
    return at(&b.symbols, l).pos;
}
