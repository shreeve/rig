//! Split builds: which unit owns each function, when a program is built
//! as several Zig compilations (`zig build-obj`, one a core) linked into
//! one executable.
//!
//! Every unit compiles the whole package. A function a unit does not own
//! starts with a call of the unit that does (`emit.Emitter.emitCut`), so
//! Zig never analyzes the rest of its body there; the owner exports it.
//! A function is cut only when every unit can call it through one
//! signature: a function or method declared at a module's top level or
//! in an object or enum with no type parameters, not inlined, with no
//! type parameters of its own, every parameter named, and not the root
//! module's `main`. Whether Zig can pass its arguments and result
//! between units is decided again where it is compiled
//! (`rig.split.crosses`), since only Zig knows the lowered signature.
//!
//! The cut follows the program in order, modules then declarations,
//! into `count` runs of about equal source size, so a unit owns
//! neighbors that mostly call each other.

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

/// Records, in each module's `sema.split_units`, the unit that owns each
/// function it cuts. Nothing is recorded for one unit.
pub fn decide(allocator: std.mem.Allocator, graph: *modules.ModuleGraph, n: u16) !void {
    if (n <= 1) return;
    var funs: std.ArrayList(Fun) = .empty;
    defer funs.deinit(allocator);
    for (graph.modules.items, 0..) |*m, i| {
        if (!m.ir.isKind(.module)) continue;
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
