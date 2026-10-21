//! Profile-guided optimization (`rig build --pgo=FILE`), from Rig's own
//! IR, since Zig has none (docs/internals/INTERNALS.md, "Profiles").
//!
//! An instrumented build counts each site: a function's entry and each
//! block emit writes with `emitBlock` (a branch's arm, a loop's body, a
//! match arm), numbered in the order emit writes them. The runtime adds
//! one to a site's counter each time it runs (`rig.pgoHit`) and writes
//! the counts when the program ends (`RIG_PGO_OUT`). The profile is a text
//! file that names each counted function by its module's Zig file, its
//! name, and a hash of its source text, so an edit to a function drops its
//! counts and leaves every other function's, and a profile never steers a
//! function it was not recorded from:
//!
//!     # rig profile 1
//!     fun __rig_main.zig parse 9c0f3e1a22b4d871 1200
//!       3 1187
//!       4 13
//!
//! `fun MODULE NAME HASH ENTRIES`, then `ORDINAL COUNT` for each of its
//! blocks that ran (the entry is ordinal 0). A function the profile has
//! that never ran is listed with 0 entries; one it lacks is unknown.
//!
//! What a build with a profile does with it: a function that the run
//! never entered is cold, as `rarely` makes it, and never inlined; a hot
//! one is inlined up to a larger size (`inlining.hot_size`); and a
//! branch's arm that rarely or never ran, or nearly always, is hinted so
//! (`Emitter.emitSite`).

const std = @import("std");

/// The name of a function in a profile: `MODULE NAME HASH`.
pub fn funKey(allocator: std.mem.Allocator, zig_file: []const u8, name: []const u8, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} {s} {x:0>16}", .{ zig_file, name, std.hash.Wyhash.hash(0x726967, text) });
}

/// One counted site of an instrumented build.
pub const Site = struct { fun: []const u8, ordinal: u32 };

/// What a profile records of one function.
pub const Fun = struct {
    entries: u64 = 0,
    /// Each block's count, by ordinal; a block missing ran never.
    blocks: std.AutoHashMapUnmanaged(u32, u64) = .empty,
};

/// What emit counts (instrumenting) or reads (with a profile).
pub const State = struct {
    allocator: std.mem.Allocator,
    instrument: bool,
    /// Instrumenting: every site, its index its counter's.
    sites: std.ArrayList(Site) = .empty,
    /// With a profile: each function it records, by `funKey`.
    funs: std.StringHashMapUnmanaged(Fun) = .empty,

    /// A new site's counter (instrumenting).
    pub fn site(self: *State, fun: []const u8, ordinal: u32) !usize {
        try self.sites.append(self.allocator, .{ .fun = fun, .ordinal = ordinal });
        return self.sites.items.len - 1;
    }

    /// What the profile records of `fun`, or null when it has nothing.
    pub fn lookup(self: *const State, fun: []const u8) ?*const Fun {
        return self.funs.getPtr(fun);
    }

    /// Whether the profile says `fun` never ran: it records the function,
    /// with no entry.
    pub fn neverRan(self: *const State, fun: []const u8) bool {
        const f = self.lookup(fun) orelse return false;
        return f.entries == 0;
    }

    /// The profile of an instrumented build's run: `counts` is what the
    /// runtime wrote (`SITE COUNT` a line). Every site's function is in
    /// it; counts of one function's sites emitted more than once add up.
    pub fn profileOf(self: *const State, counts: []const u8) !State {
        var out: State = .{ .allocator = self.allocator, .instrument = false };
        for (self.sites.items) |s| {
            const gop = try out.funs.getOrPut(self.allocator, s.fun);
            if (!gop.found_existing) gop.value_ptr.* = .{};
        }
        var lines = std.mem.tokenizeScalar(u8, counts, '\n');
        while (lines.next()) |l| {
            if (l[0] == '#') continue;
            var parts = std.mem.tokenizeScalar(u8, l, ' ');
            const i = std.fmt.parseInt(usize, parts.next() orelse continue, 10) catch return error.BadCounts;
            const n = std.fmt.parseInt(u64, parts.next() orelse return error.BadCounts, 10) catch return error.BadCounts;
            if (i >= self.sites.items.len) return error.BadCounts;
            const s = self.sites.items[i];
            const f = out.funs.getPtr(s.fun).?;
            if (s.ordinal == 0) {
                f.entries += n;
            } else {
                const gop = try f.blocks.getOrPut(self.allocator, s.ordinal);
                gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + n else n;
            }
        }
        return out;
    }

    /// The profile as its file holds it, its functions in order of name.
    pub fn write(self: *const State, w: *std.Io.Writer) !void {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        var it = self.funs.keyIterator();
        while (it.next()) |k| try names.append(self.allocator, k.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        try w.writeAll("# rig profile 1\n");
        for (names.items) |name| {
            const f = self.funs.getPtr(name).?;
            try w.print("fun {s} {d}\n", .{ name, f.entries });
            var ords: std.ArrayList(u32) = .empty;
            defer ords.deinit(self.allocator);
            var bt = f.blocks.iterator();
            while (bt.next()) |e| if (e.value_ptr.* > 0) try ords.append(self.allocator, e.key_ptr.*);
            std.mem.sort(u32, ords.items, {}, std.sort.asc(u32));
            for (ords.items) |o| try w.print("  {d} {d}\n", .{ o, f.blocks.get(o).? });
        }
    }

    /// A profile from its file's text.
    pub fn read(allocator: std.mem.Allocator, text: []const u8) !State {
        var out: State = .{ .allocator = allocator, .instrument = false };
        var current: ?*Fun = null;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |l| {
            if (l.len == 0 or l[0] == '#') continue;
            if (std.mem.startsWith(u8, l, "fun ")) {
                // `fun MODULE NAME HASH ENTRIES`: the key is all but the count.
                const cut = std.mem.lastIndexOfScalar(u8, l, ' ') orelse return error.BadProfile;
                if (cut < "fun ".len) return error.BadProfile;
                const key = try allocator.dupe(u8, l["fun ".len..cut]);
                const entries = std.fmt.parseInt(u64, l[cut + 1 ..], 10) catch return error.BadProfile;
                const gop = try out.funs.getOrPut(allocator, key);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.entries += entries;
                current = gop.value_ptr;
                continue;
            }
            const f = current orelse return error.BadProfile;
            var parts = std.mem.tokenizeScalar(u8, l, ' ');
            const o = std.fmt.parseInt(u32, parts.next() orelse return error.BadProfile, 10) catch return error.BadProfile;
            const n = std.fmt.parseInt(u64, parts.next() orelse return error.BadProfile, 10) catch return error.BadProfile;
            const gop = try f.blocks.getOrPut(allocator, o);
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + n else n;
        }
        return out;
    }
};

test "a profile reads back as it was written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var inst: State = .{ .allocator = a, .instrument = true };
    const f = try funKey(a, "__rig_main.zig", "parse", "fun parse()");
    const g = try funKey(a, "__rig_main.zig", "never", "fun never()");
    _ = try inst.site(f, 0);
    _ = try inst.site(f, 1);
    _ = try inst.site(g, 0);
    _ = try inst.site(f, 2);
    const prof = try inst.profileOf("# rig counts 1\n0 7\n1 5\n3 2\n");
    var buf: std.Io.Writer.Allocating = .init(a);
    try prof.write(&buf.writer);
    const back = try State.read(a, buf.written());
    try std.testing.expectEqual(7, back.lookup(f).?.entries);
    try std.testing.expectEqual(5, back.lookup(f).?.blocks.get(1).?);
    try std.testing.expectEqual(2, back.lookup(f).?.blocks.get(2).?);
    try std.testing.expect(back.neverRan(g));
    try std.testing.expect(!back.neverRan(f));
    try std.testing.expect(!back.neverRan("__rig_main.zig other 0000000000000000"));
}
