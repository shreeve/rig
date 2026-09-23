//! Module graph: loads a program and the modules it `use`s, and runs
//! every checker on each.
//!
//!   use foo          # loads foo.rig from the importing file's directory
//!   foo.bar(...)     # qualified access to foo's `pub` declarations
//!
//! Modules are identified by their canonical (real) path, so one file
//! reached through different spellings (`./m/a.rig`, `m/../m/a.rig`) is
//! loaded once. A module is checked after its imports; a cycle, a
//! missing module, or an import that fails to check is reported at the
//! `use` that caused it, and the importing module is not checked further
//! (its errors would only be consequences).
//!
//! Each module emits to `<name>.zig` in one output directory. Because
//! `use` resolves within a directory, module names are unique.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const types = @import("types.zig");
const effects = @import("effects.zig");
const ownership = @import("ownership.zig");
const ir_check = @import("ir.zig");

pub const max_source_bytes = 16 * 1024 * 1024;

pub const ModuleId = u32;

pub const Import = struct {
    local_name: []const u8,
    target: ModuleId,
    pos: u32, // position of the module name in `use NAME`
};

pub const Module = struct {
    /// 1-based; also the module's identity for cross-module nominal types.
    id: ModuleId,
    /// Canonical absolute path: the graph's dedup key.
    path: []const u8,
    /// The path as written by the user (or derived from the importer's),
    /// used in diagnostics.
    display: []const u8,
    /// Basename without `.rig`: the name other modules `use`.
    name: []const u8,
    /// Emitted file name: `<name>.zig`.
    out_basename: []const u8,
    source: []const u8,
    parser: *parser.Parser,
    /// Semantic IR; `.nil` if parsing failed.
    ir: parser.Sexp = .nil,
    /// Always valid, so diagnostics (including parse and import errors)
    /// can be recorded against the module's source.
    sema: *types.SemContext,
    imports: std.ArrayListUnmanaged(Import) = .empty,
    state: State = .loading,

    pub const State = enum { loading, checked, failed };
};

pub const ModuleGraph = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    /// Modules in load order; the root is first.
    modules: std.ArrayListUnmanaged(Module) = .empty,
    by_path: std.StringHashMapUnmanaged(ModuleId) = .empty,
    /// Errors with no source position (the root file cannot be read).
    errors: std.ArrayListUnmanaged([]const u8) = .empty,

    pub const Error = std.mem.Allocator.Error || rig.BindingKindError || error{Overflow};

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ModuleGraph {
        return .{ .allocator = allocator, .io = io, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *ModuleGraph) void {
        for (self.modules.items) |*m| {
            m.sema.deinit();
            self.allocator.destroy(m.sema);
            m.parser.deinit();
            self.allocator.destroy(m.parser);
            m.imports.deinit(self.allocator);
        }
        self.modules.deinit(self.allocator);
        self.by_path.deinit(self.allocator);
        self.errors.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn root(self: *ModuleGraph) *Module {
        return &self.modules.items[0];
    }

    pub fn get(self: *ModuleGraph, id: ModuleId) *Module {
        return &self.modules.items[id - 1];
    }

    pub fn hasErrors(self: *const ModuleGraph) bool {
        if (self.errors.items.len > 0) return true;
        for (self.modules.items) |m| if (m.state != .checked or m.sema.hasErrors()) return true;
        return false;
    }

    /// Load and check the program rooted at `path`. Problems are recorded
    /// as diagnostics; the error set is only for resource failures.
    pub fn loadRoot(self: *ModuleGraph, path: []const u8) Error!void {
        const a = self.arena.allocator();
        const canonical = std.Io.Dir.cwd().realPathFileAlloc(self.io, path, a) catch |err| {
            try self.errors.append(self.allocator, try std.fmt.allocPrint(a, "cannot read `{s}`: {s}", .{ path, @errorName(err) }));
            return;
        };
        const source = std.Io.Dir.cwd().readFileAlloc(self.io, canonical, a, .limited(max_source_bytes)) catch |err| {
            try self.errors.append(self.allocator, try std.fmt.allocPrint(a, "cannot read `{s}`: {s}", .{ path, @errorName(err) }));
            return;
        };
        _ = try self.load(canonical, path, source);
    }

    fn load(self: *ModuleGraph, canonical: []const u8, display: []const u8, source: []const u8) Error!ModuleId {
        const a = self.arena.allocator();
        const name = moduleName(display);

        const sema = try self.allocator.create(types.SemContext);
        errdefer self.allocator.destroy(sema);
        sema.* = try types.SemContext.init(self.allocator, source);
        const p = try self.allocator.create(parser.Parser);
        p.* = parser.Parser.init(self.allocator, source);

        const id: ModuleId = @intCast(self.modules.items.len + 1);
        try self.modules.append(self.allocator, .{
            .id = id,
            .path = canonical,
            .display = display,
            .name = name,
            .out_basename = try std.fmt.allocPrint(a, "{s}.zig", .{name}),
            .source = source,
            .parser = p,
            .sema = sema,
        });
        try self.by_path.put(self.allocator, canonical, id);

        const ir = p.parseProgram() catch |err| switch (err) {
            error.ParseError => {
                const d = p.diagnostic();
                try self.errorAt(id, d.pos, "{s}", .{d.message});
                self.get(id).state = .failed;
                return id;
            },
            else => |e| return e,
        };
        ir_check.assertValid(ir, source, display);
        self.get(id).ir = ir;

        if (!try self.loadImports(id)) {
            self.get(id).state = .failed;
            return id;
        }
        try self.check(id);
        return id;
    }

    /// Load every `use` of module `id`. Returns false if any import could
    /// not be loaded and checked.
    fn loadImports(self: *ModuleGraph, id: ModuleId) Error!bool {
        const a = self.arena.allocator();
        const ir = self.get(id).ir;
        if (ir != .list) return true;
        var ok = true;

        for (ir.items()[1..]) |decl| {
            if (decl != .list or decl.items().len < 2 or decl.items()[0] != .tag or decl.items()[0].tag != .@"use") continue;
            const name_node = decl.items()[1];
            if (name_node != .src) continue;
            const m = self.get(id);
            const local_name = m.source[name_node.src.pos..][0..name_node.src.len];
            const pos = name_node.src.pos;

            if (std.mem.eql(u8, local_name, "std")) {
                try self.errorAt(id, pos, "`use std` is reserved: Rig has no `std` module", .{});
                ok = false;
                continue;
            }

            const file = try std.fmt.allocPrint(a, "{s}.rig", .{local_name});
            const dir = std.fs.path.dirname(m.path) orelse ".";
            const display = if (std.fs.path.dirname(m.display)) |d| try std.fs.path.join(a, &.{ d, file }) else file;
            const target = try std.fs.path.join(a, &.{ dir, file });

            const canonical = std.Io.Dir.cwd().realPathFileAlloc(self.io, target, a) catch |err| {
                try self.errorAt(id, pos, "cannot read module `{s}` ({s}): {s}", .{ local_name, display, @errorName(err) });
                ok = false;
                continue;
            };

            const target_id = if (self.by_path.get(canonical)) |existing| blk: {
                if (self.get(existing).state == .loading) {
                    try self.errorAt(id, pos, "cyclic import: `{s}` is still being loaded when `{s}` imports it", .{ local_name, m.name });
                    ok = false;
                    continue;
                }
                break :blk existing;
            } else blk: {
                const source = std.Io.Dir.cwd().readFileAlloc(self.io, canonical, a, .limited(max_source_bytes)) catch |err| {
                    try self.errorAt(id, pos, "cannot read module `{s}` ({s}): {s}", .{ local_name, display, @errorName(err) });
                    ok = false;
                    continue;
                };
                break :blk try self.load(canonical, display, source);
            };

            if (self.get(target_id).state != .checked) {
                ok = false;
                continue;
            }
            try self.get(id).imports.append(self.allocator, .{ .local_name = local_name, .target = target_id, .pos = pos });
        }
        return ok;
    }

    /// Run sema, effects, and ownership on a parsed module whose imports
    /// are all checked.
    fn check(self: *ModuleGraph, id: ModuleId) Error!void {
        const m = self.get(id);
        var entries: std.ArrayListUnmanaged(types.ImportEntry) = .empty;
        defer entries.deinit(self.allocator);
        for (m.imports.items) |imp| {
            try entries.append(self.allocator, .{ .local_name = imp.local_name, .sema = self.get(imp.target).sema, .module_id = imp.target });
        }

        // Modules the imports reach in turn.
        var reached: std.ArrayListUnmanaged(types.ImportEntry) = .empty;
        defer reached.deinit(self.allocator);
        var work: std.ArrayListUnmanaged(ModuleId) = .empty;
        defer work.deinit(self.allocator);
        for (m.imports.items) |imp| try work.append(self.allocator, imp.target);
        while (work.pop()) |mid| {
            for (self.get(mid).imports.items) |imp| {
                if (imp.target == id) continue;
                const seen = for (entries.items) |e| {
                    if (e.module_id == imp.target) break true;
                } else for (reached.items) |e| {
                    if (e.module_id == imp.target) break true;
                } else false;
                if (seen) continue;
                const t = self.get(imp.target);
                try reached.append(self.allocator, .{ .local_name = t.name, .sema = t.sema, .module_id = imp.target });
                try work.append(self.allocator, imp.target);
            }
        }

        m.sema.deinit();
        m.sema.* = try types.checkWithImports(self.allocator, m.source, m.ir, entries.items, reached.items, id);

        var eff = try effects.Checker.initWithSema(self.allocator, m.source, m.sema);
        defer eff.deinit();
        try eff.check(m.ir);
        for (eff.diagnostics.items) |d| try self.addDiagnostic(id, d);

        var own = try ownership.Checker.initWithSema(self.allocator, m.source, m.sema);
        defer own.deinit();
        try own.check(m.ir);
        for (own.diagnostics.items) |d| try self.addDiagnostic(id, d);

        m.state = if (m.sema.hasErrors()) .failed else .checked;
    }

    fn errorAt(self: *ModuleGraph, id: ModuleId, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        const m = self.get(id);
        const message = try std.fmt.allocPrint(m.sema.arena.allocator(), fmt, args);
        try m.sema.diagnostics.append(self.allocator, .{ .severity = .@"error", .pos = pos, .message = message });
    }

    fn addDiagnostic(self: *ModuleGraph, id: ModuleId, d: types.Diagnostic) Error!void {
        const m = self.get(id);
        const owned = try m.sema.arena.allocator().dupe(u8, d.message);
        try m.sema.diagnostics.append(self.allocator, .{ .severity = d.severity, .pos = d.pos, .message = owned });
    }

    /// Write every diagnostic, as `path:line:col: error: message`.
    pub fn writeAllDiagnostics(self: *const ModuleGraph, w: *std.Io.Writer) !void {
        for (self.errors.items) |message| try w.print("error: {s}\n", .{message});
        for (self.modules.items) |m| try m.sema.writeDiagnostics(m.display, w);
    }
};

/// `dir/name.rig` → `name`.
fn moduleName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (std.mem.endsWith(u8, base, ".rig")) base[0 .. base.len - 4] else base;
}

test "moduleName strips the directory and .rig" {
    try std.testing.expectEqualStrings("baz", moduleName("/foo/bar/baz.rig"));
    try std.testing.expectEqualStrings("qux", moduleName("qux"));
}
