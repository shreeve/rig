//! The hashes the Zig arms use, as Rig hashes its keys (src/runtime.zig):
//! a number by one full multiply folded (`hashWord`), a key of 64-bit
//! words two at a time (`hashWords`), and `==` field by field. As
//! bench/hash/table_ctx.zig's, for the replay's key types.
const std = @import("std");

inline fn fold(a: u64, b: u64) u64 {
    const p = @as(u128, a) * b;
    return @as(u64, @truncate(p)) ^ @as(u64, @truncate(p >> 64));
}

pub fn Ctx(comptime K: type) type {
    return switch (@typeInfo(K)) {
        .int => struct {
            pub fn hash(_: @This(), x: K) u64 {
                return fold(@as(u64, @bitCast(@as(i64, x))) ^ 0x2d358dccaa6c78a5, 0x4b33a62ed433d4a3);
            }
            pub fn eql(_: @This(), a: K, b: K) bool {
                return a == b;
            }
        },
        else => struct {
            const names = std.meta.fieldNames(K);
            /// As the built-in Map, no hash kept in an entry for a plain
            /// key of at most four words.
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
        },
    };
}
