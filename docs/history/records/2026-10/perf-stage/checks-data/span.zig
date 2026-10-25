// A Span[n] into a Table of n slots: start + count <= n by construction, so t[span][k]
// tests only 0 <= k < count, which a loop over 0..count makes already.
const Span = extern struct { start: u32, count: u32 };
inline fn spanAt(slots: [*]const u32, sp: Span, k: i64) u32 {
    if (k < 0 or k >= sp.count) @panic("index out of bounds");
    return slots[sp.start + @as(u64, @intCast(k))];
}
export fn span_sum(slots: [*]const u32, sp: Span) u64 {
    var s: u64 = 0;
    var k: i64 = 0;
    const end: i64 = sp.count;
    while (k < end) : (k += 1) s +%= spanAt(slots, sp, k);
    return s;
}
// Today's form: List index of Int(start) + k against the list's length.
inline fn listAt(ptr: [*]const u32, len: usize, i: i64) u32 {
    const u = std.math.cast(usize, i) orelse @panic("index out of bounds");
    if (u >= len) @panic("index out of bounds");
    return ptr[u];
}
const std = @import("std");
export fn list_sum(ptr: [*]const u32, len: usize, sp: Span) u64 {
    var s: u64 = 0;
    var k: i64 = 0;
    const end: i64 = sp.count;
    while (k < end) : (k += 1) s +%= listAt(ptr, len, @as(i64, sp.start) + k);
    return s;
}
