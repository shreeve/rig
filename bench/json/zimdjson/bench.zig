//! zimdjson benchmark harness (Zig 0.17).
//!
//! usage: prog FILE N
//! Reads FILE once (untimed) into a buffer padded with zimdjson.padding
//! spaces, so the parser runs with .assume_padding = true (no per-call
//! copy). Then times N complete parses on the monotonic clock with one
//! reused parser and prints "<nanoseconds> <check>".
//!
//!   cfg.api == .dom       zimdjson.dom.FullParser: builds the full tape
//!                         (strings unescaped into the parser's string
//!                         buffer, numbers converted); check = tape words
//!                         + string-buffer bytes written.
//!   cfg.api == .ondemand  zimdjson.ondemand.FullParser, walked fully:
//!                         every key and string unescaped (get()),
//!                         every number converted, every bool/null read,
//!                         then trailing content checked; check folds
//!                         in every value.
const std = @import("std");
const zimdjson = @import("zimdjson");
const cfg = @import("cfg");

const gpa = std.heap.smp_allocator;
const Dom = zimdjson.dom.FullParser(.{ .assume_padding = true });
const Od = zimdjson.ondemand.FullParser(.{ .assume_padding = true });

pub fn main(init: std.process.Init.Minimal) !void {
    const args = init.args.vector;
    if (args.len != 3) {
        std.debug.print("usage: prog FILE N\n", .{});
        std.process.exit(2);
    }
    const path = std.mem.sliceTo(args[1], 0);
    const n = try std.fmt.parseInt(usize, std.mem.sliceTo(args[2], 0), 10);
    const io = std.Io.Threaded.global_single_threaded.io();

    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(raw);
    const buf = try gpa.alloc(u8, raw.len + zimdjson.padding);
    defer gpa.free(buf);
    @memcpy(buf[0..raw.len], raw);
    @memset(buf[raw.len..], ' ');
    const doc: []const u8 = buf[0..raw.len];

    var check: u64 = 0;
    var ns: u64 = 0;
    switch (cfg.api) {
        .dom => {
            var parser: Dom = .init;
            defer parser.deinit(gpa);
            const start = std.Io.Clock.Timestamp.now(io, .awake);
            for (0..n) |_| {
                _ = parser.parseFromSlice(gpa, doc) catch |err| fail(err);
                const t = &parser.tape;
                const words = (@intFromPtr(t.words_ptr) - @intFromPtr(t.words.items().ptr)) / 8;
                const strs = @intFromPtr(t.strings_ptr) - @intFromPtr(t.string_buffer.strings.items().ptr);
                check +%= words + strs;
            }
            ns = @intCast(start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toNanoseconds());
        },
        .ondemand => {
            var parser: Od = .init;
            defer parser.deinit(gpa);
            const start = std.Io.Clock.Timestamp.now(io, .awake);
            for (0..n) |_| {
                var acc: Acc = .{};
                walkDocument(&parser, doc, &acc) catch |err| fail(err);
                check +%= acc.fold();
            }
            ns = @intCast(start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toNanoseconds());
        },
        else => @compileError("cfg.api must be .dom or .ondemand"),
    }
    std.debug.print("{d} {d}\n", .{ ns, check });
}

fn fail(err: anyerror) noreturn {
    std.debug.print("parse error: {s}\n", .{@errorName(err)});
    std.process.exit(1);
}

const Acc = struct {
    count: u64 = 0,
    str_bytes: u64 = 0,
    num_bits: u64 = 0,
    fn fold(a: Acc) u64 {
        return a.count +% a.str_bytes +% a.num_bits;
    }
};

fn walkDocument(parser: *Od, doc: []const u8, acc: *Acc) !void {
    const d = try parser.parseFromSlice(gpa, doc);
    switch (try d.asAny()) {
        .null => acc.count += 1,
        .bool => |b| acc.count += 1 + @intFromBool(b),
        .number => |num| addNumber(acc, num),
        .string => |s| {
            const str = try s.get();
            acc.count += 1;
            acc.str_bytes += str.len;
        },
        .object => |o| try walkObject(o, acc, 1),
        .array => |a| try walkArray(a, acc, 1),
    }
    if (!try d.atEnd()) return error.TrailingContent;
}

fn addNumber(acc: *Acc, num: zimdjson.Number) void {
    acc.count += 1;
    acc.num_bits ^= switch (num) {
        .unsigned => |u| u,
        .signed => |i| @bitCast(i),
        .double => |f| @bitCast(f),
    };
}

// The on-demand cursor only asserts its depth limit (common.default_max_depth,
// 1024), so the walk enforces it: a container nested `depth` deep is visited
// only if its children stay below the limit, as the DOM parser's stack does.
const max_depth = 1024;

fn walkObject(o: Od.Object, acc: *Acc, depth: u32) anyerror!void {
    acc.count += 1;
    var it = o.iterator();
    while (try it.next()) |field| {
        const key = try field.key.get();
        acc.str_bytes += key.len;
        try walkValue(field.value, acc, depth);
    }
}

fn walkArray(a: Od.Array, acc: *Acc, depth: u32) anyerror!void {
    acc.count += 1;
    var it = a.iterator();
    while (try it.next()) |v| try walkValue(v, acc, depth);
}

fn walkValue(v: Od.Value, acc: *Acc, depth: u32) anyerror!void {
    switch (try v.getType()) {
        .null => {
            if (!try v.isNull()) return error.IncorrectType;
            acc.count += 1;
        },
        .bool => acc.count += 1 + @as(u64, @intFromBool(try v.asBool())),
        .number => addNumber(acc, try v.asNumber()),
        .string => {
            const str = try v.asString();
            acc.count += 1;
            acc.str_bytes += str.len;
        },
        .object => {
            if (depth + 2 >= max_depth) return error.ExceededDepth;
            try walkObject(try v.asObject(), acc, depth + 1);
        },
        .array => {
            if (depth + 2 >= max_depth) return error.ExceededDepth;
            try walkArray(try v.asArray(), acc, depth + 1);
        },
    }
}
