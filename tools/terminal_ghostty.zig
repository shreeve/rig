//! Ghostty's answers for std.terminal's differential cases: each case's
//! bytes are fed to Ghostty's terminal (libghostty-vt, at the commit
//! tools/terminal_ghostty.py pins), and its screen and cursor are printed
//! in the form std.terminal's `dump` prints them. tools/terminal_ghostty.py
//! builds and runs this with Ghostty's Zig.
//!
//! Input, a file named by the first argument: cases one after another,
//! each a line `case COLS ROWS LEN`, then LEN bytes, then a newline.
//! Output: each case's dump, then a line `end`. A dump is a line per row,
//! `|` and the row's text with its trailing blanks dropped (an empty cell
//! is a space, and the second cell of a wide character is left out), then
//! `cursor Y X`, with ` wrap` when a wrap is pending.

const std = @import("std");
const vt = @import("ghostty-vt");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) return error.Usage;
    const input = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(1 << 30));
    defer gpa.free(input);

    var buf: [1 << 16]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &fw.interface;

    var at: usize = 0;
    while (at < input.len) {
        const eol = std.mem.indexOfScalarPos(u8, input, at, '\n') orelse return error.BadCase;
        var fields = std.mem.tokenizeScalar(u8, input[at..eol], ' ');
        if (!std.mem.eql(u8, fields.next() orelse "", "case")) return error.BadCase;
        const cols = try std.fmt.parseInt(u16, fields.next() orelse return error.BadCase, 10);
        const rows = try std.fmt.parseInt(u16, fields.next() orelse return error.BadCase, 10);
        const len = try std.fmt.parseInt(usize, fields.next() orelse return error.BadCase, 10);
        const bytes = input[eol + 1 ..][0..len];
        at = eol + 1 + len + 1;
        try dumpCase(io, gpa, out, cols, rows, bytes);
    }
    try out.flush();
}

fn dumpCase(io: std.Io, gpa: std.mem.Allocator, out: *std.Io.Writer, cols: u16, rows: u16, bytes: []const u8) !void {
    var t: vt.Terminal = try .init(io, gpa, .{ .cols = cols, .rows = rows });
    defer t.deinit(gpa);
    var stream = t.vtStream();
    stream.nextSlice(bytes);

    const screen = t.screens.active;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    for (0..rows) |y| {
        line.clearRetainingCapacity();
        for (0..cols) |x| {
            const got = screen.pages.getCell(.{ .active = .{ .x = @intCast(x), .y = @intCast(y) } }) orelse continue;
            if (got.cell.wide == .spacer_tail) continue;
            const cp = got.cell.codepoint();
            var enc: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(if (cp == 0) ' ' else cp, &enc);
            try line.appendSlice(gpa, enc[0..n]);
        }
        const text = std.mem.trimEnd(u8, line.items, " ");
        try out.print("|{s}\n", .{text});
    }
    const cursor = screen.cursor;
    try out.print("cursor {d} {d}{s}\nend\n", .{ cursor.y, cursor.x, if (cursor.pending_wrap) " wrap" else "" });
}
