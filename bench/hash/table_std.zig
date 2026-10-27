//! Zig's own HashMap, as bench/hash/map.zig's `table`.
const std = @import("std");

pub const is_std = true;
pub const allocator = std.heap.c_allocator;

pub fn Auto(comptime K: type, comptime V: type) type {
    return std.AutoHashMapUnmanaged(K, V);
}

pub fn String(comptime V: type) type {
    return std.StringHashMapUnmanaged(V);
}
