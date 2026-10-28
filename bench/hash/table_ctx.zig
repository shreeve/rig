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

/// A plain key of 64-bit words, as Rig hashes and compares one: its
/// words two at a time, each pair by one folded multiply
/// (`hashWords` in src/runtime.zig), and `==` field by field. Its
/// entries keep no hash (`keep_hash`), as the built-in Map's do not for
/// a plain key of at most four words.
pub fn Words(comptime K: type) type {
    const names = @typeInfo(K).@"struct".field_names;
    return struct {
        pub const keep_hash = false;
        pub fn hash(_: @This(), k: K) u64 {
            var h: u64 = 0x2d358dccaa6c78a5;
            comptime var i: usize = 0;
            inline while (i + 1 < names.len) : (i += 2) h = fold(@field(k, names[i]) ^ h, @field(k, names[i + 1]) ^ 0x9e3779b97f4a7c15);
            if (names.len % 2 == 1) h = fold(@field(k, names[names.len - 1]) ^ h, 0x4b33a62ed433d4a3);
            return h;
        }
        pub fn eql(_: @This(), a: K, b: K) bool {
            inline for (names) |n| if (@field(a, n) != @field(b, n)) return false;
            return true;
        }
        inline fn fold(a: u64, b: u64) u64 {
            const p = @as(u128, a) * b;
            return @as(u64, @truncate(p)) ^ @as(u64, @truncate(p >> 64));
        }
    };
}

/// The allocator map.zig times with (the module `alloc`): libc's
/// `malloc` unless bench-hash names another.
pub const allocator = @import("alloc").allocator;

/// The `Auto` and `String` of a port's `HashMap(K, V, Context)`.
pub fn Tables(comptime impl: type) type {
    return struct {
        pub fn Auto(comptime K: type, comptime V: type) type {
            return impl.HashMap(K, V, if (K == i64) Int else Words(K));
        }
        pub fn String(comptime V: type) type {
            return impl.HashMap([]const u8, V, Text);
        }
    };
}
