//! replay.zig's `table` for `zig-ordered`: bench/hash/ordered.zig (the
//! module `ordered`), the design Rig's Map is built on, on Rig's hashes
//! and libc's malloc. It has no clear of its own: a clear drops the map
//! and starts an empty one.
const std = @import("std");
const ordered = @import("ordered");
const Ctx = @import("ctx.zig").Ctx;

pub const allocator = std.heap.c_allocator;

pub fn Map(comptime K: type, comptime V: type) type {
    return struct {
        const T = ordered.HashMap(K, V, Ctx(K));
        t: T = .empty,
        pub const empty: @This() = .{};
        pub fn deinit(m: *@This(), gpa: std.mem.Allocator) void {
            m.t.deinit(gpa);
        }
        pub inline fn count(m: *const @This()) usize {
            return m.t.count();
        }
        pub inline fn getPtr(m: *const @This(), k: K) ?*V {
            return m.t.getPtr(k);
        }
        pub inline fn put(m: *@This(), gpa: std.mem.Allocator, k: K, v: V) !void {
            return m.t.put(gpa, k, v);
        }
        pub inline fn fetchRemove(m: *@This(), k: K) ?T.KV {
            return m.t.fetchRemove(k);
        }
        pub inline fn valueIterator(m: *const @This()) T.ValueIterator {
            return m.t.valueIterator();
        }
        pub fn clear(m: *@This(), gpa: std.mem.Allocator) void {
            m.t.deinit(gpa);
            m.t = .empty;
        }
    };
}
