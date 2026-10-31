//! Hash maps keyed by integers, enums, pointers, and objects of them,
//! for the compiler's fact tables and memos. `std.AutoHashMap` runs
//! Wyhash over a key's bytes; these keys are node ids, positions, type
//! ids, and addresses, so one 128-bit multiply folded to 64 bits mixes
//! them as well, in a few instructions. The table is std's.

const std = @import("std");

/// A hash map from `K` to `V` hashed by `Context(K)`.
pub fn Map(comptime K: type, comptime V: type) type {
    return std.HashMapUnmanaged(K, V, Context(K), std.hash_map.default_max_load_percentage);
}

/// Hashes a `K` by `hash` and compares two by their fields.
pub fn Context(comptime K: type) type {
    return struct {
        pub fn hash(_: @This(), k: K) u64 {
            return fold(0, k);
        }
        pub fn eql(_: @This(), a: K, b: K) bool {
            return std.meta.eql(a, b);
        }
    };
}

/// Wyhash's mix: the 128-bit product of `a` and `b`, its halves xored.
/// Every bit of the result depends on every bit of `a`, so the low bits
/// std's table indexes by and the high bits it keeps as fingerprints
/// are both spread, for sequential ids and aligned addresses alike.
inline fn mix(a: u64, b: u64) u64 {
    const m = @as(u128, a) * b;
    return @as(u64, @truncate(m)) ^ @as(u64, @truncate(m >> 64));
}

/// `h` with the value `k` mixed in.
fn fold(h: u64, k: anytype) u64 {
    const T = @TypeOf(k);
    return switch (@typeInfo(T)) {
        .int => |i| mix(h ^ 0xa0761d6478bd642f ^ @as(u64, @as(@Int(.unsigned, i.bits), @bitCast(k))), 0xe7037ed1a0b428db),
        .bool => fold(h, @intFromBool(k)),
        .@"enum" => fold(h, @intFromEnum(k)),
        .pointer => |p| if (p.size == .slice) fold(fold(h, @intFromPtr(k.ptr)), k.len) else fold(h, @intFromPtr(k)),
        .optional => if (k) |v| fold(fold(h, 1), v) else fold(h, 0),
        .@"struct" => |s| blk: {
            if (s.layout == .@"packed") break :blk fold(h, @as(s.backing_integer.?, @bitCast(k)));
            var r = h;
            inline for (s.field_names) |name| r = fold(r, @field(k, name));
            break :blk r;
        },
        .@"union" => |u| blk: {
            const tag = std.meta.activeTag(k);
            var r = fold(h, tag);
            inline for (u.field_names) |name| {
                if (tag == @field(u.tag_type.?, name)) r = fold(r, @field(k, name));
            }
            break :blk r;
        },
        else => @compileError("fastmap: no hash for " ++ @typeName(T)),
    };
}

/// A fact table keyed by a `u64` whose list nodes are dense: a key
/// `1 << 32 | id` (sema's `exprKey` of a list node the parser numbered)
/// is stored at index `id` of an array, any other key in a `Map`. `V`
/// is an integer; its largest value marks an index with no entry.
pub fn DenseMap(comptime V: type) type {
    return struct {
        dense: std.ArrayList(V) = .empty,
        sparse: Map(u64, V) = .empty,

        const Self = @This();
        const none = std.math.maxInt(V);

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, a: std.mem.Allocator) void {
            self.dense.deinit(a);
            self.sparse.deinit(a);
        }

        fn denseId(key: u64) ?u32 {
            return if (key >> 32 == 1) @truncate(key) else null;
        }

        pub fn get(self: *const Self, key: u64) ?V {
            const id = denseId(key) orelse return self.sparse.get(key);
            if (id >= self.dense.items.len) return null;
            const v = self.dense.items[id];
            return if (v == none) null else v;
        }

        pub const KV = struct { key: u64, value: V };
        pub const Entry = struct { key_ptr: *const u64, value_ptr: *V };

        /// Each entry: the dense ones by id, then the others. An entry's
        /// key lives in the iterator until its next `next`.
        pub fn iterator(self: *const Self) Iterator {
            return .{ .dense = self.dense.items, .sparse = self.sparse.iterator() };
        }

        pub const Iterator = struct {
            dense: []V,
            i: u32 = 0,
            key: u64 = 0,
            sparse: Map(u64, V).Iterator,

            pub fn next(it: *Iterator) ?Entry {
                while (it.i < it.dense.len) {
                    defer it.i += 1;
                    if (it.dense[it.i] != none) {
                        it.key = 1 << 32 | @as(u64, it.i);
                        return .{ .key_ptr = &it.key, .value_ptr = &it.dense[it.i] };
                    }
                }
                const e = it.sparse.next() orelse return null;
                return .{ .key_ptr = e.key_ptr, .value_ptr = e.value_ptr };
            }
        };

        pub fn put(self: *Self, a: std.mem.Allocator, key: u64, v: V) std.mem.Allocator.Error!void {
            std.debug.assert(v != none);
            const id = denseId(key) orelse return self.sparse.put(a, key, v);
            if (id >= self.dense.items.len) try self.dense.appendNTimes(a, none, id + 1 - self.dense.items.len);
            self.dense.items[id] = v;
        }
    };
}

test "fastmap: integer and object keys" {
    var m: Map(u64, u32) = .empty;
    defer m.deinit(std.testing.allocator);
    var i: u64 = 0;
    while (i < 1000) : (i += 1) try m.put(std.testing.allocator, i | 1 << 32, @intCast(i));
    try std.testing.expectEqual(@as(?u32, 7), m.get(7 | 1 << 32));
    try std.testing.expectEqual(@as(?u32, null), m.get(7));
    const K = struct { node: u64, q: enum { a, b }, flag: bool };
    var o: Map(K, void) = .empty;
    defer o.deinit(std.testing.allocator);
    try o.put(std.testing.allocator, .{ .node = 3, .q = .a, .flag = true }, {});
    try std.testing.expect(o.contains(.{ .node = 3, .q = .a, .flag = true }));
    try std.testing.expect(!o.contains(.{ .node = 3, .q = .b, .flag = true }));
}

test "fastmap: dense map" {
    var m: DenseMap(u32) = .empty;
    defer m.deinit(std.testing.allocator);
    try m.put(std.testing.allocator, 1 << 32 | 5, 9);
    try m.put(std.testing.allocator, 77, 3);
    try std.testing.expectEqual(@as(?u32, 9), m.get(1 << 32 | 5));
    try std.testing.expectEqual(@as(?u32, null), m.get(1 << 32 | 4));
    try std.testing.expectEqual(@as(?u32, null), m.get(1 << 32 | 500));
    try std.testing.expectEqual(@as(?u32, 3), m.get(77));
}
