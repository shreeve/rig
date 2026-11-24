//! replay.zig's `table` for `zig-compact`: compact.zig, an ordered map of
//! one pointer, on Rig's hashes and libc's malloc.
const std = @import("std");
const compact = @import("compact.zig");
const Ctx = @import("ctx.zig").Ctx;

pub const allocator = std.heap.c_allocator;

pub fn Map(comptime K: type, comptime V: type) type {
    return compact.Compact(K, V, Ctx(K));
}
