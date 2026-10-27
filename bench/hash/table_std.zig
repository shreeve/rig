//! Zig's own HashMap, as bench/hash/map.zig's `table`.
const std = @import("std");

pub const is_std = true;
/// The allocator map.zig times with (the module `alloc`): libc's
/// `malloc` unless bench-hash names another.
pub const allocator = @import("alloc").allocator;

pub fn Auto(comptime K: type, comptime V: type) type {
    return std.AutoHashMapUnmanaged(K, V);
}

pub fn String(comptime V: type) type {
    return std.StringHashMapUnmanaged(V);
}
