//! Ghostty's answers for std.terminal's differential cases: each case's
//! bytes are fed to Ghostty's terminal (libghostty-vt, at the commit
//! tools/terminal_ghostty.py pins), and its screen and cursor are printed
//! in the form std.terminal's `dump` prints them. tools/terminal_ghostty.py
//! builds and runs this with Ghostty's Zig.
//!
//! `terminal_ghostty bench FILE N COLS ROWS SCROLLBACK` instead feeds
//! FILE's bytes to N new terminals of COLS by ROWS, with SCROLLBACK bytes
//! of scrollback (`none` for no limit), and prints `<ns> <check>`: the
//! nanoseconds the N feeds took, and the 64-bit FNV-1a hash of the last
//! one's dump without its final newline, which std.terminal's dump of the
//! same bytes must equal (bench/terminal).
//!
//! Input, a file named by the first argument: cases one after another,
//! each a line `case COLS ROWS LEN`, then LEN bytes, then a newline.
//! Output: each case's dump, then a line `end`. A dump is a line per row,
//! `|` and the row's text with its trailing blanks dropped (an empty cell
//! is a space, a cell shows its whole char, its grapheme's runes after
//! its own, and the second cell of a wide character is left out); then
//! a line `~Y FIRST-LAST ATTRS` for each run of cells in row Y with the same
//! style other than the default, in order; a line `reply BYTES` when the
//! terminal answered (each byte below 0x20 or above 0x7E written `\xNN`,
//! ESC `\e`, and `\` doubled); then `cursor Y X`, with ` wrap` when a wrap
//! is pending. The terminal answers through its write_pty effect, with
//! Ghostty's default device attributes and XTVERSION's name set to
//! std.terminal's. ATTRS is the style's flags (`bold italic faint
//! blink inverse invisible strike overline`, in that order, those set),
//! then `ul=single|double|curly|dotted|dashed`, `fg=`, `bg=`, and `ulc=`
//! when set, a color written as a palette index or `#rrggbb`. An empty
//! cell that holds only a background color shows it as `bg=`.

const std = @import("std");
const vt = @import("ghostty-vt");

const Handler = @FieldType(vt.TerminalStream, "handler");
const Effects = @FieldType(Handler, "effects");
const DaFn = @typeInfo(@FieldType(Effects, "device_attributes")).optional.child;
const Attributes = @typeInfo(@typeInfo(DaFn).pointer.child).@"fn".return_type.?;

/// What the terminal of the case being dumped has answered.
var replies: std.ArrayList(u8) = .empty;
var replies_gpa: std.mem.Allocator = undefined;

fn writePty(_: *Handler, data: []const u8) void {
    replies.appendSlice(replies_gpa, data) catch @panic("out of memory");
}

fn deviceAttributes(_: *Handler) Attributes {
    return .{};
}

fn xtversion(_: *Handler) []const u8 {
    return "std.terminal";
}

/// A stream for `t` whose answers go to `replies`.
fn answering(t: *vt.Terminal) vt.TerminalStream {
    var stream = t.vtStream();
    stream.handler.effects.write_pty = &writePty;
    stream.handler.effects.device_attributes = &deviceAttributes;
    stream.handler.effects.xtversion = &xtversion;
    return stream;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 7 and std.mem.eql(u8, args[1], "bench")) return bench(io, gpa, args[2..]);
    if (args.len != 2) return error.Usage;
    const input = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(1 << 30));
    defer gpa.free(input);

    replies_gpa = gpa;
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

fn bench(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, args[0], gpa, .limited(1 << 30));
    defer gpa.free(data);
    const n = try std.fmt.parseInt(usize, args[1], 10);
    const cols = try std.fmt.parseInt(u16, args[2], 10);
    const rows = try std.fmt.parseInt(u16, args[3], 10);
    const scrollback: ?usize = if (std.mem.eql(u8, args[4], "none")) null else try std.fmt.parseInt(usize, args[4], 10);
    var ns: i96 = 0;
    var check: u64 = 0;
    replies_gpa = gpa;
    for (0..n) |i| {
        var t: vt.Terminal = try .init(io, gpa, .{ .cols = cols, .rows = rows, .max_scrollback_bytes = scrollback });
        defer t.deinit(gpa);
        replies.clearRetainingCapacity();
        var stream = answering(&t);
        const start = std.Io.Clock.awake.now(io);
        stream.nextSlice(data);
        ns += start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        if (i == n - 1) {
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            try dumpScreen(gpa, &aw.writer, &t, cols, rows);
            const text = aw.written();
            check = std.hash.Fnv1a_64.hash(text[0 .. text.len - 1]);
        }
    }
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    try fw.interface.print("{d} {d}\n", .{ ns, check });
    try fw.interface.flush();
}

fn dumpCase(io: std.Io, gpa: std.mem.Allocator, out: *std.Io.Writer, cols: u16, rows: u16, bytes: []const u8) !void {
    var t: vt.Terminal = try .init(io, gpa, .{ .cols = cols, .rows = rows });
    defer t.deinit(gpa);
    replies.clearRetainingCapacity();
    var stream = answering(&t);
    stream.nextSlice(bytes);
    try dumpScreen(gpa, out, &t, cols, rows);
    try out.writeAll("end\n");
}

/// The dump of `t`, ending with a newline.
fn dumpScreen(gpa: std.mem.Allocator, out: *std.Io.Writer, t: *vt.Terminal, cols: u16, rows: u16) !void {
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
            if (got.cell.hasGrapheme()) {
                for (got.node.page().lookupGrapheme(got.cell) orelse &.{}) |g| {
                    const m = try std.unicode.utf8Encode(g, &enc);
                    try line.appendSlice(gpa, enc[0..m]);
                }
            }
        }
        const text = std.mem.trimEnd(u8, line.items, " ");
        try out.print("|{s}\n", .{text});
    }
    var run: std.ArrayList(u8) = .empty;
    defer run.deinit(gpa);
    var attr: std.ArrayList(u8) = .empty;
    defer attr.deinit(gpa);
    for (0..rows) |y| {
        run.clearRetainingCapacity();
        var first: usize = 0;
        for (0..cols + 1) |x| {
            attr.clearRetainingCapacity();
            if (x < cols) {
                const got = screen.pages.getCell(.{ .active = .{ .x = @intCast(x), .y = @intCast(y) } }).?;
                try attrs(gpa, &attr, got.cell.*, got.style());
            }
            if (std.mem.eql(u8, attr.items, run.items) and x < cols) continue;
            if (run.items.len > 0) try out.print("~{d} {d}-{d} {s}\n", .{ y, first, x - 1, run.items });
            run.clearRetainingCapacity();
            try run.appendSlice(gpa, attr.items);
            first = x;
        }
    }
    if (replies.items.len > 0) {
        try out.writeAll("reply ");
        for (replies.items) |b| switch (b) {
            0x1B => try out.writeAll("\\e"),
            '\\' => try out.writeAll("\\\\"),
            0x20...0x5B, 0x5D...0x7E => try out.writeByte(b),
            else => try out.print("\\x{x:0>2}", .{b}),
        };
        try out.writeAll("\n");
    }
    const cursor = screen.cursor;
    try out.print("cursor {d} {d}{s}\n", .{ cursor.y, cursor.x, if (cursor.pending_wrap) " wrap" else "" });
}

/// A cell's style as ATTRS (see the top of this file); empty for the default.
fn attrs(gpa: std.mem.Allocator, out: *std.ArrayList(u8), cell: vt.page.Cell, style: vt.Style) !void {
    const names = [_][]const u8{ "bold", "italic", "faint", "blink", "inverse", "invisible", "strike", "overline" };
    const f = style.flags;
    const set = [_]bool{ f.bold, f.italic, f.faint, f.blink, f.inverse, f.invisible, f.strikethrough, f.overline };
    for (names, set) |name, on| if (on) try word(gpa, out, name);
    if (f.underline != .none) try out.print(gpa, "{s}ul={s}", .{ if (out.items.len > 0) " " else "", @tagName(f.underline) });
    try color(gpa, out, "fg", style.fg_color);
    switch (cell.content_tag) {
        .bg_color_palette => try color(gpa, out, "bg", .{ .palette = cell.content.color_palette.data }),
        .bg_color_rgb => try color(gpa, out, "bg", .{ .rgb = .{ .r = cell.content.color_rgb.r, .g = cell.content.color_rgb.g, .b = cell.content.color_rgb.b } }),
        else => try color(gpa, out, "bg", style.bg_color),
    }
    try color(gpa, out, "ulc", style.underline_color);
}

fn word(gpa: std.mem.Allocator, out: *std.ArrayList(u8), w: []const u8) !void {
    if (out.items.len > 0) try out.append(gpa, ' ');
    try out.appendSlice(gpa, w);
}

fn color(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, c: vt.Style.Color) !void {
    const sep: []const u8 = if (out.items.len > 0) " " else "";
    switch (c) {
        .none => {},
        .palette => |i| try out.print(gpa, "{s}{s}={d}", .{ sep, name, i }),
        .rgb => |rgb| try out.print(gpa, "{s}{s}=#{x:0>2}{x:0>2}{x:0>2}", .{ sep, name, rgb.r, rgb.g, rgb.b }),
    }
}
