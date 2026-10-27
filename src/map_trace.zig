//! `RIG_MAP_TRACE=1` at build time: the built-in Map and Set, as emitted
//! from std/prelude.rig, made to record each of their operations
//! (`rig.mapTraceOp` in the runtime; docs/internals/INTERNALS.md, "The
//! Map trace"). Each traced method is renamed `__rig_untraced_NAME`, and
//! a method of its old name and type calls it and records what it did;
//! each type gets a field, `__rig_trace`, its id in the trace. A build
//! without the switch never comes here, so its Zig is the emitter's.
//!
//! The emitted text is the interface: a method this file names that the
//! module no longer emits as `fn NAME(`, once, inside its type, stops
//! the build with an internal error, never a trace that misses it.

const std = @import("std");

/// What a traced method's record says of it (`rig.MapOp`), and how.
const Method = struct {
    name: []const u8,
    /// Its parameters, self first.
    arity: u8,
    op: []const u8,
    /// Whether its first parameter after self is a key.
    key: bool = false,
    /// What the record's `hit` is, after the call: `r` is its result,
    /// `before` the length before it.
    hit: []const u8 = "false",
    /// The record's `extra`: the slots of a table built anew.
    extra: []const u8 = "0",
};

/// A lookup found its key; a write found it there when the length did
/// not change; a take found it when the length fell.
const found = "rig.mapTraceFound(r)";
const kept = "self.len == before";
const fell = "self.len < before";

const map_methods = [_]Method{
    .{ .name = "has", .arity = 2, .op = "get", .key = true, .hit = found },
    .{ .name = "get", .arity = 2, .op = "get", .key = true, .hit = found },
    .{ .name = "edit", .arity = 2, .op = "get", .key = true, .hit = found },
    // `put` calls `replace`, which records it.
    .{ .name = "replace", .arity = 3, .op = "put", .key = true, .hit = kept },
    .{ .name = "put_new", .arity = 3, .op = "put", .key = true, .hit = kept },
    .{ .name = "ensure", .arity = 3, .op = "put", .key = true, .hit = kept },
    .{ .name = "ensure_added", .arity = 3, .op = "put", .key = true, .hit = kept },
    .{ .name = "ensure_with", .arity = 3, .op = "put", .key = true, .hit = kept },
    .{ .name = "take", .arity = 2, .op = "remove", .key = true, .hit = fell },
    .{ .name = "clear", .arity = 1, .op = "clear" },
    .{ .name = "rebuild", .arity = 2, .op = "grow", .extra = "@intCast(a1)" },
    .{ .name = "retain", .arity = 2, .op = "retain" },
};

const set_methods = [_]Method{
    .{ .name = "has", .arity = 2, .op = "get", .key = true, .hit = found },
    .{ .name = "add", .arity = 2, .op = "put", .key = true, .hit = kept },
    .{ .name = "take", .arity = 2, .op = "remove", .key = true, .hit = fell },
    .{ .name = "clear", .arity = 1, .op = "clear" },
    .{ .name = "rebuild", .arity = 2, .op = "grow", .extra = "@intCast(a1)" },
    .{ .name = "retain", .arity = 2, .op = "retain" },
};

const Traced = struct {
    head: []const u8,
    /// The value type the runtime is given: `void` for a Set.
    value: []const u8,
    methods: []const Method,
};

const traced = [_]Traced{
    .{ .head = "pub fn Map(comptime K: type, comptime __rig_plain_K: bool, comptime V: type, comptime __rig_plain_V: bool) type {\n", .value = "V", .methods = &map_methods },
    .{ .head = "pub fn Set(comptime K: type, comptime __rig_plain_K: bool) type {\n", .value = "void", .methods = &set_methods },
};

pub const Error = error{ OutOfMemory, WriteFailed, MapTraceDrift };

/// The Zig of module std.prelude, `zig`, with its Map and Set
/// traced. On `error.MapTraceDrift`, `what` says what it did not find.
pub fn instrument(a: std.mem.Allocator, zig: []const u8, what: *[]const u8) Error![]const u8 {
    var text = zig;
    for (traced) |t| text = try instrumentType(a, text, t, what);
    return text;
}

fn instrumentType(a: std.mem.Allocator, zig: []const u8, t: Traced, what: *[]const u8) Error![]const u8 {
    const start = std.mem.indexOf(u8, zig, t.head) orelse return drift(what, t.head);
    const end = std.mem.indexOfPos(u8, zig, start, "\n}\n") orelse return drift(what, t.head);
    var body: []const u8 = zig[start..end];
    for (t.methods) |m| {
        const decl = try std.fmt.allocPrint(a, "fn {s}(", .{m.name});
        if (std.mem.count(u8, body, decl) != 1) return drift(what, decl);
        body = try std.mem.replaceOwned(u8, a, body, decl, try std.fmt.allocPrint(a, "fn __rig_untraced_{s}(", .{m.name}));
    }
    // The field goes last among the fields, which end where the type's
    // declarations start with its name; the methods follow that line.
    const name_decl = "\n        pub const __rig_name = ";
    if (std.mem.count(u8, body, name_decl) != 1) return drift(what, name_decl[1..]);
    const at = std.mem.indexOf(u8, body, name_decl).? + 1;
    const line_end = std.mem.indexOfScalarPos(u8, body, at, '\n').? + 1;
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll(zig[0..start]);
    try w.writeAll(body[0..at]);
    try w.writeAll("        __rig_trace: u32 = 0,\n");
    try w.writeAll(body[at..line_end]);
    for (t.methods) |m| try writeWrapper(w, m, t.value);
    try w.writeAll(body[line_end..]);
    try w.writeAll(zig[end..]);
    return out.written();
}

fn drift(what: *[]const u8, missing: []const u8) error{MapTraceDrift} {
    what.* = missing;
    return error.MapTraceDrift;
}

/// `NAME` of the type's old signature, which names the Map to the trace
/// (a Map it has not seen gets its id), calls `__rig_untraced_NAME`, and
/// records the call.
fn writeWrapper(w: *std.Io.Writer, m: Method, value: []const u8) std.Io.Writer.Error!void {
    try w.print("\n        pub inline fn {s}(self: rig.MapTraceParam(__rig_untraced_{s}, 0)", .{ m.name, m.name });
    for (1..m.arity) |i| try w.print(", a{d}: rig.MapTraceParam(__rig_untraced_{s}, {d})", .{ i, m.name, i });
    try w.print(") rig.MapTraceResult(__rig_untraced_{s}) {{\n", .{m.name});
    try w.print("            rig.mapTraceSee(K, {s}, self);\n", .{value});
    if (std.mem.indexOf(u8, m.hit, "before") != null) try w.writeAll("            const before = self.len;\n");
    if (m.key) try w.writeAll("            const key = rig.mapTraceKey(K, a1);\n");
    try w.print("            const r = self.__rig_untraced_{s}(", .{m.name});
    for (1..m.arity) |i| try w.print("{s}a{d}", .{ if (i > 1) ", " else "", i });
    try w.writeAll(");\n");
    try w.print("            rig.mapTraceOp(K, {s}, self, .{s}, {s}, {s}, {s});\n", .{ value, m.op, if (m.key) "key" else ".{}", m.hit, m.extra });
    try w.writeAll("            return r;\n        }\n");
}

test "instrument renames each traced method and wraps it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.Io.Writer.Allocating = .init(a);
    for (traced) |t| {
        try src.writer.writeAll(t.head);
        try src.writer.writeAll("    return struct {\n        len: i64 = 0,\n        pub const __rig_name = .{};\n");
        for (t.methods) |m| try src.writer.print("        pub fn {s}() void {{}}\n", .{m.name});
        try src.writer.writeAll("    };\n}\n");
    }
    var what: []const u8 = "";
    const out = try instrument(a, src.written(), &what);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "__rig_trace: u32 = 0,"));
    try std.testing.expectEqual(@as(usize, map_methods.len + set_methods.len), std.mem.count(u8, out, "rig.mapTraceOp("));
    try std.testing.expect(std.mem.indexOf(u8, out, "fn __rig_untraced_ensure_with(") != null);
    // A method the module no longer emits stops the build.
    try std.testing.expectError(error.MapTraceDrift, instrument(a, "pub fn Map(comptime K: type, comptime V: type) type {\n}\n", &what));
}
