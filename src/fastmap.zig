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

/// A hash map from `K` to `V` hashed by `Context(K)` that keeps its
/// entries in the order they were put, which no key's value decides.
pub fn OrderedMap(comptime K: type, comptime V: type) type {
    return std.ArrayHashMapUnmanaged(K, V, struct {
        pub fn hash(_: @This(), k: K) u32 {
            return @truncate(fold(0, k));
        }
        pub fn eql(_: @This(), a: K, b: K, _: usize) bool {
            return std.meta.eql(a, b);
        }
    }, false);
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

/// A fact table keyed by sema's `exprKey`, held as two arrays: a list
/// node's key, `1 << 32 | id`, at index `id` of `nodes`, and a leaf's
/// key, its leaf id, at that index of `leaves`. `V` is an integer; its
/// largest value marks an index with no entry.
pub fn DenseMap(comptime V: type) type {
    return struct {
        nodes: std.ArrayList(V) = .empty,
        leaves: std.ArrayList(V) = .empty,

        const Self = @This();
        const none = std.math.maxInt(V);

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, a: std.mem.Allocator) void {
            self.nodes.deinit(a);
            self.leaves.deinit(a);
        }

        /// The array that holds `key`, and its index there.
        fn slot(self: anytype, key: u64) struct { @TypeOf(&self.nodes), u32 } {
            std.debug.assert(key >> 32 <= 1);
            return .{ if (key >> 32 == 1) &self.nodes else &self.leaves, @truncate(key) };
        }

        pub fn get(self: *const Self, key: u64) ?V {
            const list, const i = self.slot(key);
            if (i >= list.items.len) return null;
            const v = list.items[i];
            return if (v == none) null else v;
        }

        pub fn contains(self: *const Self, key: u64) bool {
            return self.get(key) != null;
        }

        pub const KV = struct { key: u64, value: V };
        pub const Entry = struct { key_ptr: *const u64, value_ptr: *V };

        /// Each entry: the nodes by id, then the leaves by id. An entry's
        /// key lives in the iterator until its next `next`.
        pub fn iterator(self: *const Self) Iterator {
            return .{ .nodes = self.nodes.items, .leaves = self.leaves.items };
        }

        pub const Iterator = struct {
            nodes: []V,
            leaves: []V,
            i: u32 = 0,
            key: u64 = 0,

            pub fn next(it: *Iterator) ?Entry {
                while (it.i < it.nodes.len + it.leaves.len) {
                    defer it.i += 1;
                    const leaf = it.i >= it.nodes.len;
                    const at: u32 = if (leaf) @intCast(it.i - it.nodes.len) else it.i;
                    const list = if (leaf) it.leaves else it.nodes;
                    if (list[at] != none) {
                        it.key = if (leaf) at else 1 << 32 | @as(u64, at);
                        return .{ .key_ptr = &it.key, .value_ptr = &list[at] };
                    }
                }
                return null;
            }
        };

        pub fn put(self: *Self, a: std.mem.Allocator, key: u64, v: V) std.mem.Allocator.Error!void {
            std.debug.assert(v != none);
            const list, const i = self.slot(key);
            if (i >= list.items.len) try list.appendNTimes(a, none, i + 1 - list.items.len);
            list.items[i] = v;
        }

        pub fn remove(self: *Self, key: u64) bool {
            const list, const i = self.slot(key);
            if (i >= list.items.len or list.items[i] == none) return false;
            list.items[i] = none;
            return true;
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
    try std.testing.expectEqual(@as(?u32, null), m.get(5));
    var it = m.iterator();
    try std.testing.expectEqual(@as(u64, 1 << 32 | 5), it.next().?.key_ptr.*);
    try std.testing.expectEqual(@as(u64, 77), it.next().?.key_ptr.*);
    try std.testing.expect(it.next() == null);
    try std.testing.expect(m.remove(77));
    try std.testing.expect(!m.remove(77));
    try std.testing.expect(!m.contains(77));
}
