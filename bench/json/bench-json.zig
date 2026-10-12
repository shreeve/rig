//! The Zig std.json baselines for bench/json/bench-json: a measuring stick, built with -OReleaseFast and -OReleaseSafe.
//!
//! usage: bench-json-zig MODE N
//!   MODE tape   std.json.Scanner, building the same tape std/json.rig
//!               builds: every token validated (UTF-8 too), escaped
//!               strings decoded into one text buffer, unescaped ones
//!               left in the input, numbers converted to i64 or f64
//!               exactly as std.json.Value does.
//!   MODE value  std.json.parseFromSlice(std.json.Value): the usual
//!               std.json DOM, which also hashes every object's keys.
//! Prints the nanoseconds the N parses took and a checksum.
const std = @import("std");
const json = std.json;

const input = @embedFile("input.json");
const gpa = std.heap.smp_allocator; // what a Rig program allocates from

const Tape = struct {
    tape: std.ArrayList(i64) = .empty,
    text: std.ArrayList(u8) = .empty,
    floats: std.ArrayList(f64) = .empty,
    ints: std.ArrayList(i64) = .empty,
    stack: std.ArrayList(usize) = .empty,

    fn push(t: *Tape, e: i64) !void {
        try t.tape.append(gpa, e);
    }

    fn parse(t: *Tape) !void {
        t.tape.clearRetainingCapacity();
        t.text.clearRetainingCapacity();
        t.floats.clearRetainingCapacity();
        t.ints.clearRetainingCapacity();
        t.stack.clearRetainingCapacity();
        var sc = json.Scanner.initCompleteInput(gpa, input);
        defer sc.deinit();
        var escaped_from: ?usize = null;
        while (true) {
            switch (try sc.next()) {
                .object_begin => try t.open(10),
                .array_begin => try t.open(8),
                .object_end, .array_end => {
                    const start = t.stack.pop().?;
                    const tag = t.tape.items[start];
                    t.tape.items[start] = @as(i64, @intCast(t.tape.items.len)) * 16 + tag;
                    try t.push(@as(i64, @intCast(start)) * 16 + tag + 1);
                },
                .null => try t.push(0),
                .false => try t.push(1),
                .true => try t.push(2),
                .number => |n| try t.number(n),
                .string => |s| {
                    if (escaped_from) |off| {
                        try t.text.appendSlice(gpa, s);
                        try t.push(@as(i64, @intCast((off << 27) + (t.text.items.len - off))) * 16 + 7);
                        escaped_from = null;
                    } else {
                        const off = @intFromPtr(s.ptr) - @intFromPtr(input.ptr);
                        try t.push(@as(i64, @intCast((off << 27) + s.len)) * 16 + 6);
                    }
                },
                .partial_string => |s| try t.partial(&escaped_from, s),
                .partial_string_escaped_1 => |b| try t.partial(&escaped_from, &b),
                .partial_string_escaped_2 => |b| try t.partial(&escaped_from, &b),
                .partial_string_escaped_3 => |b| try t.partial(&escaped_from, &b),
                .partial_string_escaped_4 => |b| try t.partial(&escaped_from, &b),
                .end_of_document => return,
                else => unreachable,
            }
        }
    }

    fn open(t: *Tape, tag: i64) !void {
        try t.stack.append(gpa, t.tape.items.len);
        try t.push(tag);
    }

    fn partial(t: *Tape, from: *?usize, s: []const u8) !void {
        if (from.* == null) from.* = t.text.items.len;
        try t.text.appendSlice(gpa, s);
    }

    fn number(t: *Tape, n: []const u8) !void {
        if (json.isNumberFormattedLikeAnInteger(n)) {
            if (std.fmt.parseInt(i64, n, 10)) |v| {
                if (v >= -(1 << 59) + 1 and v < (1 << 59)) return t.push(v * 16 + 3);
                try t.push(@as(i64, @intCast(t.ints.items.len)) * 16 + 4);
                return t.ints.append(gpa, v);
            } else |_| {}
        }
        const f = try std.fmt.parseFloat(f64, n);
        if (!std.math.isFinite(f)) return error.SyntaxError;
        try t.push(@as(i64, @intCast(t.floats.items.len)) * 16 + 5);
        try t.floats.append(gpa, f);
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    const args = init.args.vector;
    const mode = std.mem.sliceTo(args[1], 0);
    const n = try std.fmt.parseInt(usize, std.mem.sliceTo(args[2], 0), 10);
    const io = std.Io.Threaded.global_single_threaded.io();
    var check: usize = 0;
    var t: Tape = .{};
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    if (std.mem.eql(u8, mode, "tape")) {
        for (0..n) |_| {
            try t.parse();
            check += t.tape.items.len;
        }
    } else {
        for (0..n) |_| {
            const parsed = try json.parseFromSlice(json.Value, gpa, input, .{});
            check += switch (parsed.value) {
                .object => |o| o.count(),
                .array => |a| a.items.len,
                else => 1,
            };
            parsed.deinit();
        }
    }
    const ns = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toNanoseconds();
    std.debug.print("{d} {d}\n", .{ ns, check });
}
