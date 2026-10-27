//! The hashes a port in bench/hash races with, as map.zig's `table`:
//! Rig's hash of an Int (`hashWord` in src/runtime.zig), which the C++
//! and Rust `-mix` variants use too, and Wyhash over a text's bytes.
const std = @import("std");

pub const Int = struct {
    pub fn hash(_: Int, x: i64) u64 {
        const p = @as(u128, @as(u64, @bitCast(x)) ^ 0x2d358dccaa6c78a5) * 0x4b33a62ed433d4a3;
        return @as(u64, @truncate(p)) ^ @as(u64, @truncate(p >> 64));
    }
    pub fn eql(_: Int, a: i64, b: i64) bool {
        return a == b;
    }
};

pub const Text = struct {
    pub fn hash(_: Text, s: []const u8) u64 {
        return std.hash.Wyhash.hash(0, s);
    }
    pub fn eql(_: Text, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

/// libc's `malloc`, as the C++ and Rust contestants allocate from.
pub const allocator = std.heap.c_allocator;

/// The `Auto` and `String` of a port's `HashMap(K, V, Context)`.
pub fn Tables(comptime impl: type) type {
    return struct {
        pub fn Auto(comptime K: type, comptime V: type) type {
            comptime std.debug.assert(K == i64);
            return impl.HashMap(K, V, Int);
        }
        pub fn String(comptime V: type) type {
            return impl.HashMap([]const u8, V, Text);
        }
    };
}
