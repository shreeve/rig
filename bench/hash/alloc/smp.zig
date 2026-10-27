//! Zig's `smp_allocator`, the general-purpose allocator Zig's own
//! compiler uses in release builds.
const std = @import("std");

pub const allocator = std.heap.smp_allocator;
