//! The node store: a fact column by node id. A column whose values are
//! large and whose nodes are many is held as an array of slots by node
//! id, each the place of its value in a list of values, rather than as a
//! hash map: a lookup is two loads, and the values sit packed, where a
//! map keeps a slot for each of its spare places too.
//!
//! A column holds a fact for one list node the parser numbered. It has
//! the read API of a `fastmap.Map` (`get`, `contains`), and the writes
//! the trail makes (`put`, `remove`; `sema.SemContext.putIn`).

const std = @import("std");
const parser = @import("parser.zig");

pub const NodeId = parser.NodeId;

/// The facts of column `V` by node id.
pub fn NodeTable(comptime V: type) type {
    return struct {
        /// By node id: the index of its value in `values`, plus one, or
        /// zero for a node without one.
        slots: std.ArrayList(u32) = .empty,
        values: std.ArrayList(V) = .empty,

        const Self = @This();

        pub const empty: Self = .{};
        pub const KV = struct { key: NodeId, value: V };

        pub fn deinit(self: *Self, a: std.mem.Allocator) void {
            self.slots.deinit(a);
            self.values.deinit(a);
        }

        pub fn get(self: *const Self, id: NodeId) ?V {
            if (id >= self.slots.items.len) return null;
            const at = self.slots.items[id];
            return if (at == 0) null else self.values.items[at - 1];
        }

        pub fn contains(self: *const Self, id: NodeId) bool {
            return id < self.slots.items.len and self.slots.items[id] != 0;
        }

        /// Gives node `id` the value `v`, in place of any it had.
        pub fn put(self: *Self, a: std.mem.Allocator, id: NodeId, v: V) std.mem.Allocator.Error!void {
            if (id >= self.slots.items.len) try self.slots.appendNTimes(a, 0, id + 1 - self.slots.items.len);
            const at = self.slots.items[id];
            if (at != 0) {
                self.values.items[at - 1] = v;
                return;
            }
            try self.values.append(a, v);
            self.slots.items[id] = @intCast(self.values.items.len);
        }

        pub const Entry = struct { key_ptr: *const NodeId, value_ptr: *V };

        /// Each entry, by node id. An entry's key lives in the iterator
        /// until its next `next`.
        pub fn iterator(self: *const Self) Iterator {
            return .{ .table = self };
        }

        pub const Iterator = struct {
            table: *const Self,
            id: NodeId = 0,
            key: NodeId = 0,

            pub fn next(it: *Iterator) ?Entry {
                const slots = it.table.slots.items;
                while (it.id < slots.len) {
                    defer it.id += 1;
                    if (slots[it.id] != 0) {
                        it.key = it.id;
                        return .{ .key_ptr = &it.key, .value_ptr = &it.table.values.items[slots[it.id] - 1] };
                    }
                }
                return null;
            }
        };

        /// Takes node `id`'s value away; its place in `values` stays
        /// unused.
        pub fn remove(self: *Self, id: NodeId) bool {
            if (!self.contains(id)) return false;
            self.slots.items[id] = 0;
            return true;
        }
    };
}

test "a node table gets what was put, and nothing else" {
    const a = std.testing.allocator;
    var t: NodeTable(u64) = .empty;
    defer t.deinit(a);
    try t.put(a, 5, 50);
    try t.put(a, 2, 20);
    try t.put(a, 5, 51);
    try std.testing.expectEqual(@as(?u64, 51), t.get(5));
    try std.testing.expectEqual(@as(?u64, 20), t.get(2));
    try std.testing.expectEqual(@as(?u64, null), t.get(3));
    try std.testing.expectEqual(@as(?u64, null), t.get(500));
    try std.testing.expect(t.remove(5));
    try std.testing.expect(!t.contains(5));
    try std.testing.expect(!t.remove(5));
    try t.put(a, 5, 52);
    try std.testing.expectEqual(@as(?u64, 52), t.get(5));
}
