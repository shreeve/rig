//! The program's symbols: every `:name` literal of every module, std
//! included, numbered once for the whole program after checking.
//!
//! The names are deduplicated and sorted bytewise, so the ids depend on
//! the set of names alone, never on the order modules are read in. They
//! are written to one file, `__rig_symbols.zig` (`emit.symbols_filename`),
//! which every module that writes a symbol imports as `__rig_sym`:
//!
//!     pub const Symbol = enum(u32) { @"height" = 0, @"width" = 1, _, ... };
//!
//! A module writes `:width` as the tag `__rig_sym.Symbol.@"width"`, never
//! as its id, so adding a symbol anywhere changes only this file. The
//! enum is open (`_`): a Zig `switch` on it always has an `else`, which
//! is what a Rig `match` on a `Symbol` requires (`_ =>`). The id
//! `0xFFFF_FFFF` is never given.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const nametable = @import("nametable.zig");

const Sexp = parser.Sexp;

/// The ids `0xFFFF_FFFF` and up are reserved.
pub const max_symbols: usize = 0xFFFF_FFFF;

/// A module's source and its tree.
pub const Source = struct { source: []const u8, ir: Sexp };

/// The names of every symbol written in `sources`, each once, sorted
/// bytewise, allocated in `a`.
pub fn collect(a: std.mem.Allocator, sources: []const Source) ![]const []const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    var names: std.ArrayList([]const u8) = .empty;
    for (sources) |s| try walk(a, s.source, s.ir, &seen, &names);
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn walk(a: std.mem.Allocator, source: []const u8, e: Sexp, seen: *std.StringHashMapUnmanaged(void), names: *std.ArrayList([]const u8)) !void {
    if (e != .list) return;
    if (e.isKind(.symbol)) {
        const name = rig.leafText(source, parser.ir.Symbol.name(e).src);
        if (!seen.contains(name)) {
            try seen.put(a, name, {});
            try names.append(a, name);
        }
        return;
    }
    for (e.items()) |c| try walk(a, source, c, seen, names);
}

/// `__rig_symbols.zig` for `names`, sorted and different
/// (`collect`): the enum, each symbol's text, and the table
/// `Symbol.from_text(word)` finds a name in.
pub fn write(a: std.mem.Allocator, w: *std.Io.Writer, names: []const []const u8, runtime_path: []const u8) !void {
    std.debug.assert(names.len < max_symbols);
    try w.writeAll("//! The program's symbols, numbered by their sorted text.\n\n");
    try w.print("const rig = @import(\"{s}\");\n\n", .{runtime_path});
    try w.writeAll("pub const Symbol = enum(u32) {\n");
    for (names, 0..) |name, i| try w.print("    @\"{f}\" = {d},\n", .{ std.zig.fmtString(name), i });
    try w.writeAll("    _,\n\n    pub const __rig_symbol = true;\n\n");
    // With no symbols, no `Symbol` value is ever made: `fromText` finds
    // none.
    if (names.len == 0) {
        try w.writeAll("    pub fn text(s: Symbol) []const u8 {\n        _ = s;\n        unreachable;\n    }\n};\n\n");
    } else try w.writeAll("    pub fn text(s: Symbol) []const u8 {\n        return table.names[@intFromEnum(s)];\n    }\n};\n\n");
    try w.writeAll("const table: rig.NameTable = ");
    try nametable.write(w, names, try nametable.build(a, names));
    try w.writeAll(";\n\n");
    try w.writeAll("pub fn fromText(word: []const u8) ?Symbol {\n    return @enumFromInt(table.find(word) orelse return null);\n}\n");
}

test "symbols are numbered by their sorted text, each once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "width", "height", "width", "if", "a-b" }) |n| if (!seen.contains(n)) {
        try seen.put(a, n, {});
        try names.append(a, n);
    };
    std.mem.sort([]const u8, names.items, {}, lessThan);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "a-b", "height", "if", "width" }), @as([]const []const u8, names.items));
    var out: std.Io.Writer.Allocating = .init(a);
    try write(a, &out.writer, names.items, "rig/runtime.zig");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "@\"a-b\" = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "@\"width\" = 3,") != null);
}
