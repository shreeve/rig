//! The table that finds a fixed set of names by their text, built by the
//! compiler and emitted as constant data: a plain enum's variants for
//! `E.from_text(word)`. The runtime's `rig.NameTable` reads it, and owns
//! the hash and the tag, so both sides agree by construction.

const std = @import("std");
const runtime = @import("runtime.zig");

pub const NameTable = runtime.NameTable;

/// The slots of a table (`rig.NameTable`).
pub const Table = struct {
    tags: []const u8,
    slots: []const u32,
};

/// The table of `names`, all different, allocated in `a`.
pub fn build(a: std.mem.Allocator, names: []const []const u8) !Table {
    // A power of two of at least 16, at most four fifths full.
    var size: usize = 16;
    while (names.len * 5 > size * 4) size *= 2;
    const tags = try a.alloc(u8, size);
    @memset(tags, 0);
    const slots = try a.alloc(u32, size);
    @memset(slots, 0);
    const last = size - 1;
    for (names, 0..) |name, id| {
        const h = NameTable.hashOf(name);
        var i: usize = @intCast(h & last);
        while (tags[i] != 0) i = (i + 1) & last;
        tags[i] = NameTable.tagOf(h);
        slots[i] = @intCast(id);
    }
    return .{ .tags = tags, .slots = slots };
}

/// `.{ .names = &.{ "a", "b" }, .tags = &.{ ... }, .slots = &.{ ... } }`:
/// the `rig.NameTable` of `names`, whose slots are `t`.
pub fn write(w: *std.Io.Writer, names: []const []const u8, t: Table) !void {
    try w.writeAll(".{ .names = &.{");
    for (names, 0..) |name, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(" \"{f}\"", .{std.zig.fmtString(name)});
    }
    try w.writeAll(" }, .tags = &.{");
    for (t.tags, 0..) |tag, i| try w.print("{s}{d}", .{ if (i > 0) ", " else " ", tag });
    try w.writeAll(" }, .slots = &.{");
    for (t.slots, 0..) |slot, i| try w.print("{s}{d}", .{ if (i > 0) ", " else " ", slot });
    try w.writeAll(" } }");
}

test "a built table finds every name and no other" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]usize{ 0, 1, 3, 12, 13, 16, 64, 256, 1000 }) |n| {
        const names = try a.alloc([]const u8, n);
        for (names, 0..) |*name, i| name.* = try std.fmt.allocPrint(a, "name_{d}", .{i});
        const t = try build(a, names);
        try std.testing.expect(std.math.isPowerOfTwo(t.tags.len) and t.tags.len >= 16);
        try std.testing.expect(n * 5 <= t.tags.len * 4);
        const table: NameTable = .{ .names = names, .tags = t.tags, .slots = t.slots };
        for (names, 0..) |name, i| try std.testing.expectEqual(@as(?u32, @intCast(i)), table.find(name));
        for ([_][]const u8{ "", "name_", "Name_0", "name_00", "name_1000000", "x" }) |miss| {
            try std.testing.expectEqual(@as(?u32, null), table.find(miss));
        }
    }
}
