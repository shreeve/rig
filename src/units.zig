//! Split builds: which unit owns each function, when a program is built
//! as several Zig compilations (`zig build-obj`, one a core) linked into
//! one executable.
//!
//! Every unit compiles every module's declarations. The body of a cut
//! function is compiled by the one unit that owns it, which exports it;
//! every other unit compiles a call of the owner's in its place
//! (`emit.Emitter.emitCut`, `main.splitFiles`). A function is cut only
//! when every unit can call it through one signature: a function or
//! method declared at a module's top level or in an object or enum with
//! no type parameters, not inlined, with no type parameters of its own,
//! every parameter named, and not the root module's `main`. Such a
//! function lowers to a Zig function with no compile-time parameter
//! that returns, which `rig.split.call` checks where it is compiled.
//!
//! The cut follows the program in order, modules then declarations,
//! into `count` runs of about equal source size, so a unit owns
//! neighbors that mostly call each other. A build that changed only
//! bodies since the last one in its directory keeps that build's owners
//! (`keep`), so each of its other units compiles what it did then.

const std = @import("std");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const modules = @import("modules.zig");
const rig = @import("rig.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;

/// A program splits once its own modules reach two chunks of this many
/// lines, into one unit a chunk, up to the cores at hand (`count`). A
/// unit's fixed cost (std, the runtime, and the inline and generic code
/// each unit compiles again) is about a second; a chunk costs several
/// (docs/internals/INTERNALS.md, "Split builds"). Std's modules are not
/// counted: Zig compiles only what the program uses of them.
pub const chunk_lines = 9_000;

/// How many units to build `graph` as: one below two chunks, else one a
/// chunk, at most `cores`.
pub fn count(graph: *const modules.ModuleGraph, cores: usize) u16 {
    var lines: usize = 0;
    for (graph.modules.items) |m| if (!m.is_std) {
        lines += std.mem.countScalar(u8, m.source, '\n');
    };
    const chunks = lines / chunk_lines;
    if (chunks < 2) return 1;
    return @intCast(@max(1, @min(chunks, cores, std.math.maxInt(u16))));
}

const Fun = struct { sema: *sema.SemContext, pos: u32, size: u32 };

/// Records, in each module's `sema.split_units`, each function it cuts
/// and the unit that owns it by the cut. Nothing is recorded for one
/// unit, or for the module of the built-in `Map` and `Set` when it is
/// `whole_prelude`.
pub fn decide(allocator: std.mem.Allocator, graph: *modules.ModuleGraph, n: u16, whole_prelude: bool) !void {
    if (n <= 1) return;
    var funs: std.ArrayList(Fun) = .empty;
    defer funs.deinit(allocator);
    for (graph.modules.items, 0..) |*m, i| {
        if (!m.ir.isKind(.module)) continue;
        if (whole_prelude and m.is_std and std.mem.eql(u8, m.name, "std." ++ rig.builtin_module_name)) continue;
        try collect(allocator, &funs, m.sema, ir.Module.decls(m.ir), i == 0, true);
    }
    var total: u64 = 0;
    for (funs.items) |f| total += f.size;
    var at: u64 = 0;
    for (funs.items) |f| {
        const unit: u16 = @intCast(@min(n - 1, at * n / @max(total, 1)));
        try f.sema.split_units.put(f.sema.allocator, f.pos, unit);
        at += f.size;
    }
}

const table_head = "rig units 1";

/// The owner of each cut function of a build of `n` units: `owners`
/// holds `decide`'s for each, by its symbol in `names`, and is left
/// holding the owners to build with. `old` is the table the last build
/// in the directory returned, or empty. When that build had `n` units
/// and the same `shared` (the hash of every file all the units read,
/// which holds every declaration and a call for every cut function, so
/// the two builds cut the same functions and differ only in bodies),
/// each function keeps the owner it had: a body that grew or shrank
/// moves no function to another unit, and only the units whose bodies
/// changed read anything new. Otherwise every unit reads something new
/// and `decide`'s owners stand. Any owners build the same program: the
/// table only spares compiles. Returns the table to keep.
pub fn keep(allocator: std.mem.Allocator, old: []const u8, n: u16, shared: []const u8, names: []const []const u8, owners: []u16) ![]const u8 {
    var lines = std.mem.splitScalar(u8, old, '\n');
    const head = try std.fmt.allocPrint(allocator, table_head ++ " {d} {s}", .{ n, shared });
    if (std.mem.eql(u8, lines.first(), head)) {
        var had: std.StringHashMapUnmanaged(u16) = .empty;
        defer had.deinit(allocator);
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const unit = std.fmt.parseInt(u16, line[0..space], 10) catch continue;
            if (unit < n) try had.put(allocator, line[space + 1 ..], unit);
        }
        for (names, owners) |name, *owner| owner.* = had.get(name) orelse owner.*;
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    try out.writer.print("{s}\n", .{head});
    for (names, owners) |name, owner| try out.writer.print("{d} {s}\n", .{ owner, name });
    return out.written();
}

test "keep: owners stay while only bodies change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = [_][]const u8{ "rigx_m__f", "rigx_m__g", "rigx_m__h" };
    var owners = [_]u16{ 0, 0, 1 };
    const first = try keep(a, "", 2, "aa", &names, &owners);
    try std.testing.expectEqualStrings("rig units 1 2 aa\n0 rigx_m__f\n0 rigx_m__g\n1 rigx_m__h\n", first);
    // `g` grew: the cut would move it, the table keeps it.
    owners = .{ 0, 1, 1 };
    const second = try keep(a, first, 2, "aa", &names, &owners);
    try std.testing.expectEqualSlices(u16, &.{ 0, 0, 1 }, &owners);
    try std.testing.expectEqualStrings(first, second);
    // A declaration changed, or the count of units: the cut stands.
    owners = .{ 0, 1, 1 };
    _ = try keep(a, first, 2, "bb", &names, &owners);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 1 }, &owners);
    owners = .{ 0, 1, 2 };
    _ = try keep(a, first, 3, "aa", &names, &owners);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2 }, &owners);
}

fn collect(allocator: std.mem.Allocator, funs: *std.ArrayList(Fun), s: *sema.SemContext, decls: []const Sexp, root: bool, top: bool) !void {
    for (decls) |d0| {
        // A compile-time function runs in the checker, and is not emitted.
        if (rig.isCtFun(d0)) continue;
        const d = rig.unpub(d0);
        const kind = d.kind() orelse continue;
        switch (kind) {
            .fun, .sub => if (cuttable(s, d, root and top)) try funs.append(allocator, .{
                .sema = s,
                .pos = s.startOf(ir.get(d, .name)),
                .size = @intCast(s.span(d).end - s.span(d).start),
            }),
            .@"struct" => try collect(allocator, funs, s, ir.Struct.members(d), root, false),
            .@"enum" => try collect(allocator, funs, s, ir.Enum.members(d), root, false),
            else => {},
        }
    }
}

fn cuttable(s: *sema.SemContext, node: Sexp, root_top: bool) bool {
    const name = ir.get(node, .name);
    if (ir.get(node, .body) == .nil) return false;
    if (root_top and std.mem.eql(u8, sema.identAt(s.source, name) orelse "", "main")) return false;
    if (s.inlined.contains(s.startOf(name))) return false;
    const tparams = sema.tparamsOf(node);
    if (tparams == .list and tparams.items().len > 0) return false;
    const params = ir.get(node, .params);
    if (params == .list) for (params.items()) |p| {
        const pname = sema.paramName(s.source, p) orelse return false;
        if (std.mem.eql(u8, pname, "_")) return false;
    };
    return true;
}
