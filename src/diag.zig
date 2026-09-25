//! Diagnostics shared by the compiler passes.
//!
//! A `Diagnostic` is a severity, a source range of the module (usually
//! the span of the IR node it is about), and a message. Passes collect
//! them and the CLI prints each as `file:line:col: error: message` at the
//! start of the range, followed by the source line with the range
//! underlined (notes are indented and attach to the preceding error).
//!
//! Node spans come from the parser (`parser.Parser.span`); `leafSpan`
//! is the fallback for a tree without them. `lineCol` turns a byte
//! offset into a 1-based line and column.

const std = @import("std");
const parser = @import("parser.zig");

const Sexp = parser.Sexp;

pub const Severity = enum { @"error", note };

pub const Span = parser.Span;

pub const Diagnostic = struct {
    severity: Severity,
    /// Where the diagnostic points: the start of its range.
    pos: u32,
    /// End of the range (exclusive); at most `pos` for a single point.
    end: u32 = 0,
    message: []const u8,
};

pub fn hasErrorsIn(items: []const Diagnostic) bool {
    for (items) |d| {
        if (d.severity == .@"error") return true;
    }
    return false;
}

/// The most errors the CLI prints for one program; it counts the rest.
pub const max_errors = 100;

/// Print `items` as `path:line:col: error: message`. Never fails on
/// odd input: an empty path, an empty source, or a position past the
/// end of the source all still print something readable.
pub fn write(items: []const Diagnostic, source: []const u8, file_path: []const u8, w: anytype) !void {
    var budget: u32 = std.math.maxInt(u32);
    _ = try writeSome(items, source, file_path, w, &budget);
}

/// `write` while `budget` lasts: each error takes one from it, and its
/// notes print with it. Returns how many errors were not printed.
pub fn writeSome(items: []const Diagnostic, source: []const u8, file_path: []const u8, w: anytype, budget: *u32) !u32 {
    const path = if (file_path.len == 0) "<unknown>" else file_path;
    var lines: Lines = .{ .source = source };
    var hidden: u32 = 0;
    var showing = true;
    for (items) |d| {
        if (d.severity == .@"error") {
            showing = budget.* > 0;
            if (showing) budget.* -= 1 else hidden += 1;
        }
        if (!showing) continue;
        const tag = switch (d.severity) {
            .@"error" => "error",
            .note => "  note",
        };
        const msg = if (d.message.len == 0) "(no message)" else d.message;
        if (source.len == 0) {
            try w.print("{s}: {s}: {s}\n", .{ path, tag, msg });
        } else {
            const lc = lines.at(d.pos);
            try w.print("{s}:{d}:{d}: {s}: {s}\n", .{ path, lc.line, lc.col, tag, msg });
            try writeExcerpt(source, d.pos, d.end, w);
        }
    }
    return hidden;
}

/// The widest excerpt printed: a longer line is cut to the part around
/// the position, with `...` marking each cut.
const max_excerpt = 120;

/// The source line holding `pos`, then a line underlining the range
/// `pos..end` on it (`^` at `pos`, `~` for the rest of the range, which
/// stops at the end of the line). Tabs are copied into the underline so
/// it stays aligned; each UTF-8 character is one column.
pub fn writeExcerpt(source: []const u8, pos: u32, end: u32, w: anytype) !void {
    const at: usize = @min(pos, source.len);
    var start = at;
    while (start > 0 and source[start - 1] != '\n') start -= 1;
    var stop = at;
    while (stop < source.len and source[stop] != '\n' and source[stop] != '\r') stop += 1;
    var cut_start = false;
    if (at - start > max_excerpt / 2) {
        start = at - max_excerpt / 2;
        while (start < at and isContinuation(source[start])) start += 1;
        cut_start = true;
    }
    var cut_stop = false;
    if (stop - start > max_excerpt) {
        stop = start + max_excerpt;
        while (stop > at and isContinuation(source[stop])) stop -= 1;
        cut_stop = true;
    }
    const lead = if (cut_start) "..." else "";
    try w.print("{s}{s}{s}\n", .{ lead, source[start..stop], if (cut_stop) "..." else "" });
    try w.writeAll(if (cut_start) "   " else "");
    for (source[start..at]) |c| {
        if (c == '\t') try w.writeByte('\t') else if (!isContinuation(c)) try w.writeByte(' ');
    }
    try w.writeByte('^');
    const last = @min(@as(usize, @max(end, pos)), stop);
    if (last > at + 1) for (source[at + 1 .. last]) |c| {
        if (!isContinuation(c)) try w.writeByte('~');
    };
    try w.writeByte('\n');
}

fn isContinuation(c: u8) bool {
    return c & 0xC0 == 0x80;
}

pub const LineCol = struct { line: u32, col: u32 };

/// 1-based line and column of byte offset `pos`. A tab counts as one
/// column, and so does each UTF-8 character. Positions past the end
/// clamp to the end of the source.
pub fn lineCol(source: []const u8, pos: u32) LineCol {
    var lines: Lines = .{ .source = source };
    return lines.at(pos);
}

/// `lineCol` for many positions of one source: each lookup continues
/// from the previous one, so ascending positions cost one pass in all.
pub const Lines = struct {
    source: []const u8,
    pos: usize = 0,
    lc: LineCol = .{ .line = 1, .col = 1 },

    pub fn at(self: *Lines, pos: u32) LineCol {
        const end = @min(pos, self.source.len);
        if (end < self.pos) self.* = .{ .source = self.source };
        for (self.source[self.pos..end]) |c| {
            if (c == '\n') {
                self.lc.line += 1;
                self.lc.col = 1;
            } else if (!isContinuation(c)) self.lc.col += 1;
        }
        self.pos = end;
        return self.lc;
    }
};

/// The range from the first to the end of the last source token in
/// `sexp`: a node's span as far as its leaves tell. Keywords and
/// punctuation are not leaves, so this is a fallback for trees without
/// the parser's spans; it is empty at 0 for a node without leaves.
pub fn leafSpan(sexp: Sexp) Span {
    switch (sexp) {
        .src => |s| return .{ .start = s.pos, .end = s.pos + s.len },
        .list => {
            var out: ?Span = null;
            for (sexp.items()) |c| {
                const cs = leafSpan(c);
                if (cs.end == 0) continue;
                out = if (out) |o| .{ .start = @min(o.start, cs.start), .end = @max(o.end, cs.end) } else cs;
            }
            return out orelse .empty;
        },
        else => return .empty,
    }
}

test "lineCol: counts lines and columns from 1" {
    const src = "ab\ncd\n";
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 1 }, lineCol(src, 0));
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 2 }, lineCol(src, 1));
    try std.testing.expectEqual(LineCol{ .line = 2, .col = 1 }, lineCol(src, 3));
    try std.testing.expectEqual(LineCol{ .line = 3, .col = 1 }, lineCol(src, 999));
    // A UTF-8 character is one column.
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 4 }, lineCol("\"é\"x", 4));
}

test "write: position, message, and the range underlined on its line" {
    const src = "sub main()\n  x = foo(1, 2)\n  y\n";
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const at: u32 = 17; // `foo`
    try write(&.{
        .{ .severity = .@"error", .pos = at, .end = at + 9, .message = "bad call" },
        .{ .severity = .note, .pos = 0, .message = "here" },
    }, src, "m.rig", &w);
    try std.testing.expectEqualStrings(
        \\m.rig:2:7: error: bad call
        \\  x = foo(1, 2)
        \\      ^~~~~~~~~
        \\m.rig:1:1:   note: here
        \\sub main()
        \\^
        \\
    , w.buffered());
}

test "writeSome: stops at the budget and counts the rest" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var budget: u32 = 1;
    const hidden = try writeSome(&.{
        .{ .severity = .@"error", .pos = 0, .message = "one" },
        .{ .severity = .note, .pos = 0, .message = "its note" },
        .{ .severity = .@"error", .pos = 1, .message = "two" },
        .{ .severity = .note, .pos = 1, .message = "not shown" },
    }, "ab", "m.rig", &w, &budget);
    try std.testing.expectEqual(@as(u32, 1), hidden);
    try std.testing.expectEqualStrings(
        \\m.rig:1:1: error: one
        \\ab
        \\^
        \\m.rig:1:1:   note: its note
        \\ab
        \\^
        \\
    , w.buffered());
}

test "writeExcerpt: a long line is cut around the position" {
    const line = "x" ** 100 ++ "é" ++ "y" ** 100;
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeExcerpt(line, 102, 105, &w);
    const out = w.buffered();
    const first = out[0..std.mem.indexOfScalar(u8, out, '\n').?];
    try std.testing.expectEqualStrings("..." ++ "x" ** 58 ++ "é" ++ "y" ** 60 ++ "...", first);
    try std.testing.expectEqualStrings(" " ** 62 ++ "^~~\n", out[first.len + 1 ..]);
}

test "leafSpan: from the first leaf to the end of the last" {
    var inner = [_]Sexp{ .{ .tag = .@"+" }, .{ .src = .{ .pos = 4, .len = 1, .id = 0 } }, .{ .src = .{ .pos = 8, .len = 2, .id = 0 } } };
    const s = leafSpan(Sexp.listOf(&inner));
    try std.testing.expectEqual(@as(u32, 4), s.start);
    try std.testing.expectEqual(@as(u32, 10), s.end);
}
