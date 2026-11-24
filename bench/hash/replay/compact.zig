//! A prototype ordered map whose value is one pointer (8 bytes): every
//! part of the table, its header included, lives in one block the
//! pointer names, and an empty map is a null pointer that has allocated
//! nothing. For bench/hash/replay's `zig-compact` arm; a measurement, not
//! a part of Rig.
//!
//! The block: a header (32 bytes), one tag byte an entry (`etags`, at
//! least 16, 0 for an entry gone or not written), the entries in the
//! order their keys were first put, and, past `small` entries, an index:
//! `groups` groups of 16 control bytes (0 free, 1 a tombstone, 128-255 a
//! tag) and, beside them, one u32 entry index a lane.
//!
//! Up to `small` (16) entries a map has no index: one 16-lane match of
//! the hash's tag against `etags` finds its candidates. Past that a key's
//! probe starts at the group its hash's high bits name and walks groups
//! triangularly until a group with a free lane. A take marks its entry
//! gone and its lane a tombstone (free when its group has a free lane),
//! so the order of the rest survives; the entries are compacted when the
//! block is full and a quarter of them are gone. `clear` keeps the block
//! and empties the index in place (a memset of its control bytes), so a
//! cache cleared and filled again builds no index anew.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Compact(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        pub const KV = struct { key: K, value: V };
        const E = struct { key: K, value: V };
        const ctx: Context = undefined;
        const small = 16;
        const first_cap = 4;

        const Header = extern struct {
            cap: u32,
            len: u32,
            live: u32,
            groups: u32,
            /// Inserts left before the index must grow: free lanes past
            /// the maximum load, tombstones counted as used.
            room: u32,
            shift: u32,
            _pad: [8]u8 = undefined,
        };
        const eoff = std.mem.alignForward(usize, @sizeOf(Header) + small, @alignOf(E));

        block: ?[*]align(16) u8 = null,

        pub const empty: Self = .{};

        inline fn hdr(self: *const Self) *Header {
            return @ptrCast(self.block.?);
        }

        fn etagBytes(cap: usize) usize {
            return @max(cap, small);
        }

        fn entriesOffset(cap: usize) usize {
            return std.mem.alignForward(usize, @sizeOf(Header) + etagBytes(cap), @alignOf(E));
        }

        fn ctrlOffset(cap: usize) usize {
            return std.mem.alignForward(usize, entriesOffset(cap) + cap * @sizeOf(E), 16);
        }

        fn blockBytes(cap: usize, groups: usize) usize {
            return ctrlOffset(cap) + groups * 16 * (1 + 4);
        }

        inline fn etags(self: *const Self) [*]u8 {
            return self.block.? + @sizeOf(Header);
        }

        inline fn entries(self: *const Self) [*]E {
            return @ptrCast(@alignCast(self.block.? + entriesOffset(self.hdr().cap)));
        }

        inline fn ctrl(self: *const Self) [*]u8 {
            return self.block.? + ctrlOffset(self.hdr().cap);
        }

        inline fn slots(self: *const Self) [*]u32 {
            const h = self.hdr();
            return @ptrCast(@alignCast(self.block.? + ctrlOffset(h.cap) + h.groups * 16));
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            if (self.block) |b| {
                const h = self.hdr();
                gpa.free(b[0..blockBytes(h.cap, h.groups)]);
            }
            self.* = .{};
        }

        pub fn count(self: *const Self) usize {
            return if (self.block == null) 0 else self.hdr().live;
        }

        inline fn tagOf(h: u64) u8 {
            return @as(u8, @truncate(h)) | 0x80;
        }

        inline fn match16(p: [*]const u8, t: u8) u16 {
            const v: @Vector(16, u8) = p[0..16].*;
            return @bitCast(v == @as(@Vector(16, u8), @splat(t)));
        }

        /// The entry index of `k`, or null.
        inline fn find(self: *const Self, k: K, h: u64) ?u32 {
            const hd = self.hdr();
            const es = self.entries();
            const t = tagOf(h);
            if (hd.groups == 0) {
                var m = match16(self.etags(), t);
                while (m != 0) : (m &= m - 1) {
                    const i = @ctz(m);
                    if (ctx.eql(es[i].key, k)) return i;
                }
                return null;
            }
            const cs = self.ctrl();
            const ss = self.slots();
            const mask = hd.groups - 1;
            var g: u32 = @as(u32, @intCast(h >> @intCast(hd.shift))) & (hd.groups - 1);
            var step: u32 = 0;
            while (true) {
                const base = g * 16;
                var m = match16(cs + base, t);
                while (m != 0) : (m &= m - 1) {
                    const e = ss[base + @ctz(m)];
                    if (ctx.eql(es[e].key, k)) return e;
                }
                if (match16(cs + base, 0) != 0) return null;
                step += 1;
                g = (g + step) & mask;
            }
        }

        pub inline fn getPtr(self: *const Self, k: K) ?*V {
            if (self.block == null) return null;
            const i = self.find(k, ctx.hash(k)) orelse return null;
            return &self.entries()[i].value;
        }

        /// The lane of the index that holds entry `e` of hash `h`.
        fn laneOf(self: *const Self, h: u64, e: u32) u32 {
            const hd = self.hdr();
            const cs = self.ctrl();
            const ss = self.slots();
            const t = tagOf(h);
            var g: u32 = @as(u32, @intCast(h >> @intCast(hd.shift))) & (hd.groups - 1);
            var step: u32 = 0;
            while (true) {
                const base = g * 16;
                var m = match16(cs + base, t);
                while (m != 0) : (m &= m - 1) {
                    if (ss[base + @ctz(m)] == e) return base + @ctz(m);
                }
                step += 1;
                g = (g + step) & (hd.groups - 1);
            }
        }

        /// Write entry `e` of hash `h` into the index at its first free
        /// or tombstone lane.
        fn place(self: *Self, h: u64, e: u32) void {
            const hd = self.hdr();
            const cs = self.ctrl();
            const ss = self.slots();
            var g: u32 = @as(u32, @intCast(h >> @intCast(hd.shift))) & (hd.groups - 1);
            var step: u32 = 0;
            while (true) {
                const base = g * 16;
                const v: @Vector(16, u8) = cs[base..][0..16].*;
                const free: u16 = @bitCast(v < @as(@Vector(16, u8), @splat(2)));
                if (free != 0) {
                    const l = base + @ctz(free);
                    if (cs[l] == 0) hd.room -= 1;
                    cs[l] = tagOf(h);
                    ss[l] = e;
                    return;
                }
                step += 1;
                g = (g + step) & (hd.groups - 1);
            }
        }

        fn groupsFor(n: usize) usize {
            // The live entries fill at most 7/8 of the lanes.
            var g: usize = 1;
            while (g * 16 * 7 / 8 < n) g *= 2;
            return g;
        }

        /// A new block of `cap` entries holding the live ones, in order,
        /// with an index when `cap` passes `small`.
        fn rebuild(self: *Self, gpa: Allocator, cap: usize) Allocator.Error!void {
            const groups: usize = if (cap > small) groupsFor(cap) else 0;
            const nb = try gpa.alignedAlloc(u8, .@"16", blockBytes(cap, groups));
            const nh: *Header = @ptrCast(nb.ptr);
            nh.* = .{ .cap = @intCast(cap), .len = 0, .live = 0, .groups = @intCast(groups), .room = 0, .shift = 0 };
            const net = nb.ptr + @sizeOf(Header);
            @memset(net[0..etagBytes(cap)], 0);
            if (groups != 0) {
                @memset((nb.ptr + ctrlOffset(cap))[0 .. groups * 16], 0);
                nh.room = @intCast(groups * 16 * 7 / 8);
                nh.shift = @intCast(64 - @as(u32, std.math.log2_int(usize, groups)));
                if (groups == 1) nh.shift = 63;
            }
            var next: Self = .{ .block = nb.ptr };
            if (self.block) |_| {
                const hd = self.hdr();
                const es = self.entries();
                const et = self.etags();
                const nes = next.entries();
                var j: u32 = 0;
                for (0..hd.len) |i| {
                    if (et[i] == 0) continue;
                    nes[j] = es[i];
                    net[j] = et[i];
                    if (groups != 0) next.place(ctx.hash(es[i].key), j);
                    j += 1;
                }
                nh.len = j;
                nh.live = j;
                self.deinit(gpa);
            }
            self.* = next;
        }

        pub fn put(self: *Self, gpa: Allocator, k: K, v: V) Allocator.Error!void {
            const h = ctx.hash(k);
            if (self.block != null) {
                if (self.find(k, h)) |i| {
                    self.entries()[i].value = v;
                    return;
                }
            }
            try self.insertNew(gpa, k, v, h);
        }

        fn insertNew(self: *Self, gpa: Allocator, k: K, v: V, h: u64) Allocator.Error!void {
            if (self.block == null) {
                try self.rebuild(gpa, first_cap);
            } else {
                const hd = self.hdr();
                if (hd.len == hd.cap) {
                    // Full: compact when a quarter is gone, else grow.
                    const cap: usize = if (hd.cap - hd.live >= hd.cap / 4 and hd.live < hd.cap) hd.cap else hd.cap * 2;
                    try self.rebuild(gpa, cap);
                } else if (hd.groups != 0 and hd.room == 0) {
                    try self.rebuild(gpa, hd.cap);
                }
            }
            const hd = self.hdr();
            const e = hd.len;
            self.entries()[e] = .{ .key = k, .value = v };
            self.etags()[e] = tagOf(h);
            if (hd.groups != 0) self.place(h, e);
            hd.len += 1;
            hd.live += 1;
        }

        pub fn fetchRemove(self: *Self, k: K) ?KV {
            if (self.block == null) return null;
            const h = ctx.hash(k);
            const e = self.find(k, h) orelse return null;
            const hd = self.hdr();
            const ent = self.entries()[e];
            if (hd.groups != 0) {
                const l = self.laneOf(h, e);
                const cs = self.ctrl();
                const base = l & ~@as(u32, 15);
                if (match16(cs + base, 0) != 0) {
                    cs[l] = 0;
                    hd.room += 1;
                } else {
                    cs[l] = 1;
                }
            }
            self.etags()[e] = 0;
            hd.live -= 1;
            if (hd.live == 0) self.clear(undefined);
            return .{ .key = ent.key, .value = ent.value };
        }

        /// Drop every entry; the block stays, its index emptied in place.
        pub fn clear(self: *Self, gpa: Allocator) void {
            _ = gpa;
            if (self.block == null) return;
            const hd = self.hdr();
            @memset(self.etags()[0..etagBytes(hd.cap)], 0);
            if (hd.groups != 0) {
                @memset(self.ctrl()[0 .. hd.groups * 16], 0);
                hd.room = hd.groups * 16 * 7 / 8;
            }
            hd.len = 0;
            hd.live = 0;
        }

        pub const ValueIterator = struct {
            es: [*]E,
            et: [*]const u8,
            i: u32,
            n: u32,
            pub inline fn next(it: *ValueIterator) ?*V {
                while (it.i < it.n) {
                    const i = it.i;
                    it.i += 1;
                    if (it.et[i] != 0) return &it.es[i].value;
                }
                return null;
            }
        };

        pub fn valueIterator(self: *const Self) ValueIterator {
            if (self.block == null) return .{ .es = undefined, .et = undefined, .i = 0, .n = 0 };
            return .{ .es = self.entries(), .et = self.etags(), .i = 0, .n = self.hdr().len };
        }
    };
}

test "compact against a model" {
    const Ctx = struct {
        pub fn hash(_: @This(), x: u32) u64 {
            const p = @as(u128, @as(u64, x) ^ 0x2d358dccaa6c78a5) * 0x4b33a62ed433d4a3;
            return @as(u64, @truncate(p)) ^ @as(u64, @truncate(p >> 64));
        }
        pub fn eql(_: @This(), a: u32, b: u32) bool {
            return a == b;
        }
    };
    const gpa = std.testing.allocator;
    var m: Compact(u32, u64, Ctx) = .empty;
    defer m.deinit(gpa);
    var model: std.AutoArrayHashMapUnmanaged(u32, u64) = .empty;
    defer model.deinit(gpa);
    var rng = std.Random.DefaultPrng.init(7);
    const r = rng.random();
    for (0..400_000) |step| {
        const range: u32 = if (step % 100_000 < 50_000) 40 else 3000;
        const k = r.uintLessThan(u32, range);
        switch (r.uintLessThan(u8, 10)) {
            0...3 => {
                try m.put(gpa, k, step);
                try model.put(gpa, k, step);
            },
            4...6 => try std.testing.expectEqual(model.get(k), if (m.getPtr(k)) |p| p.* else null),
            7, 8 => {
                const a = m.fetchRemove(k);
                const b = model.orderedRemove(k);
                try std.testing.expectEqual(b, a != null);
            },
            else => if (r.uintLessThan(u16, 2000) == 0) {
                m.clear(gpa);
                model.clearRetainingCapacity();
            },
        }
        try std.testing.expectEqual(model.count(), m.count());
    }
    // Walks in insertion order.
    var it = m.valueIterator();
    for (model.values()) |v| try std.testing.expectEqual(v, it.next().?.*);
    try std.testing.expectEqual(null, it.next());
}
