//! replay.zig's `table` for `zig-compact`: compact.zig, an ordered map of
//! one pointer, on Rig's hashes and allocator.
const std = @import("std");
const compact = @import("compact.zig");
const Ctx = @import("ctx.zig").Ctx;

/// Rig's release allocator (src/alloc.zig, the module `alloc`), as the
/// built-in Map allocates from in a release build.
pub const allocator = @import("alloc").allocator;

pub fn Map(comptime K: type, comptime V: type) type {
    return compact.Compact(K, V, Ctx(K));
}
