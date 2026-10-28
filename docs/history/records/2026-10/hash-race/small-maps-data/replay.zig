//! Built from src/: copy it there beside main's src/ordered.zig as zz_ordered_main.zig
//! (and, for micro.zig, another table as zz_gm.zig), then zig build-exe -OReleaseFast.
//! A replay of Trig's U32-keyed Map and Set operations (a compacted
//! RIG_MAP_TRACE) against the table of main (`zz_ordered_main.zig`) and
//! this branch (`ordered.zig`): `replay FILE old|new [reps]`. The tables'
//! objects sit in one array a kind, as Trig's List[Map] holds them.
const std = @import("std");
const rt = @import("runtime.zig");
const new = @import("ordered.zig");
const old = @import("zz_ordered_main.zig");

const mem_build = @hasDecl(@import("root"), "__rig_memory");

const Rec = extern struct { op: u8, kind: u8, pad: u16, id: u32, key: u32 };

fn run(comptime Mod: type, recs: []const Rec, counts: [3]u32) u64 {
    const A = Mod.OrderedMap(u32, u32);
    const B = Mod.OrderedMap(u32, i64);
    const S = Mod.OrderedSet(u32);
    const a = rt.allocSlice(A, counts[0]);
    const b = rt.allocSlice(B, counts[1]);
    const s = rt.allocSlice(S, counts[2]);
    @memset(a, .{});
    @memset(b, .{});
    @memset(s, .{});
    var check: u64 = 0;
    for (recs, 0..) |r, n| {
        switch (r.kind) {
            0 => {
                const t = &a[r.id];
                switch (r.op) {
                    0 => check +%= if (t.find(r.key)) |j| @as(u64, t.value(j)) else 1,
                    1 => check +%= @intFromBool(t.put(r.key, @truncate(n))),
                    2 => check +%= if (rt.some(t.take(r.key))) |v| v else 3,
                    3 => t.clear(),
                    5 => t.__rig_drop(),
                    else => {},
                }
            },
            1 => {
                const t = &b[r.id];
                switch (r.op) {
                    0 => check +%= if (t.find(r.key)) |j| @as(u64, @bitCast(t.value(j))) else 1,
                    1 => check +%= @intFromBool(t.put(r.key, @intCast(n))),
                    2 => check +%= if (rt.some(t.take(r.key))) |v| @as(u64, @bitCast(v)) else 3,
                    3 => t.clear(),
                    5 => t.__rig_drop(),
                    else => {},
                }
            },
            else => {
                const t = &s[r.id];
                switch (r.op) {
                    0 => check +%= @intFromBool(t.find(r.key) != null),
                    1 => check +%= @intFromBool(t.add(r.key)),
                    2 => check +%= if (rt.some(t.take(r.key))) |v| v else 3,
                    3 => t.clear(),
                    5 => t.__rig_drop(),
                    else => {},
                }
            },
        }
    }
    for (a) |*t| t.__rig_drop();
    for (b) |*t| t.__rig_drop();
    for (s) |*t| t.__rig_drop();
    rt.freeSlice(A, a);
    rt.freeSlice(B, b);
    rt.freeSlice(S, s);
    return check;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    const io = init.io;
    const data = try std.Io.Dir.cwd().readFileAlloc(io, args[1], init.gpa, .unlimited);
    const counts: [3]u32 = @bitCast(data[0..12].*);
    const recs = std.mem.bytesAsSlice(Rec, data[12..]);
    const is_old = std.mem.eql(u8, args[2], "old");
    const reps: usize = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 1;
    var best: u64 = std.math.maxInt(u64);
    var check: u64 = 0;
    for (0..reps) |_| {
        const t0 = std.Io.Timestamp.now(io, .awake);
        check = if (is_old) run(old, @alignCast(recs), counts) else run(new, @alignCast(recs), counts);
        const ns: u64 = @intCast(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds());
        best = @min(best, ns);
    }
    const peak: i64 = if (mem_build) rt.fast_alloc.totals().peak else 0;
    std.debug.print("{s} best {d} us, check {d}, peak {d} bytes\n", .{ if (is_old) "old" else "new", best / 1000, check, peak });
}
