//! Rig Module System (M15).
//!
//! Multi-file projects: `use foo` resolves to `foo.rig` in the same
//! directory as the importing file. Each `.rig` becomes its own
//! `.zig` in a generated output directory; the root file's emitted
//! Zig imports its dependencies via `@import("foo.zig")`.
//!
//! Per the M15 design pass with GPT-5.5 (conversation
//! `c_7552c1a82c518dcf`):
//!
//! ## Surface (V1)
//!
//!   use foo                   # same-dir lookup, simple ident only
//!   foo.bar(...)              # qualified access, fn call
//!   foo.User(name: "Steve")   # qualified construction
//!   foo.Color.red             # qualified enum access
//!
//! Deferred: aliases (`use foo as f`), package paths (`use std.io`),
//! unqualified imports (`use foo.bar` → bare `bar` in scope),
//! visibility enforcement.
//!
//! ## Compilation model
//!
//! Recursive load with cycle detection. Each module is parsed,
//! sema'd, effects-checked, ownership-checked, then emitted to its
//! own `.zig` file in a generated output directory.
//!
//! Cycle detection uses the standard tri-state walk (unvisited /
//! visiting / done). Re-imports of an already-loaded module return
//! the cached `ModuleId`.
//!
//! ## Cross-module type checking — M15 v1 deferred
//!
//! Sema recognizes `use foo` as a `.module`-kinded symbol but does
//! NOT yet look up `foo.bar` in foo's `SemContext`. Member access
//! on a module-kinded LHS silently types as `unknown` and lowers
//! to literal `foo.bar` Zig syntax — Zig's type checker handles
//! the cross-file resolution at compile time.
//!
//! This means cross-module call type-checking, constructor-arg
//! validation, etc. all happen in Zig rather than Rig at this
//! milestone. M15b will add proper sema-driven cross-module
//! resolution.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const types = @import("types.zig");
const effects = @import("effects.zig");
const ownership = @import("ownership.zig");

pub const ModuleId = u32;
pub const invalid_module: ModuleId = 0;

pub const LoadState = enum { visiting, done };

/// All errors the module driver can produce. Declared explicitly so
/// the recursive `loadByPath` ↔ `collectAndLoadImports` pair doesn't
/// trip Zig's inferred-error-set cycle detection.
pub const Error =
    std.mem.Allocator.Error ||
    rig.BindingKindError ||
    error{Overflow};

pub const Import = struct {
    local_name: []const u8, // arena-borrowed; the `foo` in `use foo`
    target: ModuleId,
    pos: u32, // source pos of the `use` keyword (for cycle diagnostics)
};

pub const Module = struct {
    id: ModuleId,
    /// Canonical absolute path of the source `.rig` file. Used as the
    /// dedup key in the graph and as the basis for the emitted `.zig`
    /// path.
    path: []const u8,
    /// Local name — basename of `path` minus `.rig`. This is what
    /// appears in `use NAME` forms when other modules import this one.
    name: []const u8,
    /// Source text — owned in the graph's arena.
    source: []const u8,
    /// Parser instance — keeps the IR arena alive for the module's
    /// lifetime. Pointer-stable; we never reallocate.
    p: *parser.Parser,
    /// Normalized IR — points into `p`'s arena.
    ir: parser.Sexp,
    /// Per-module sema context. Pointer-stable so other modules can
    /// hold references for cross-module symbol lookup (M15b+).
    sema: *types.SemContext,
    /// Resolved imports in declaration order.
    imports: std.ArrayListUnmanaged(Import) = .empty,
    /// Output `.zig` path (basename only; e.g., `foo.zig`).
    out_basename: []const u8,
};

pub const Diagnostic = struct {
    /// Module that owns the position. May be `invalid_module` for
    /// global-graph errors (e.g., file-not-found).
    module: ModuleId,
    pos: u32,
    message: []const u8,
};

/// Module graph. Owns all loaded modules + their sema contexts +
/// all arena memory used during the driver pass.
pub const ModuleGraph = struct {
    allocator: std.mem.Allocator,
    /// I/O context for file reads. Set on init.
    io: std.Io,
    /// Owns paths, names, source text, copies of imports.
    arena: std.heap.ArenaAllocator,
    /// Slot 0 reserved for `invalid_module`.
    modules: std.ArrayListUnmanaged(Module) = .empty,
    /// Canonical-path → ModuleId for dedup.
    by_path: std.StringHashMapUnmanaged(ModuleId) = .empty,
    /// Load state (cycle detection).
    state: std.AutoHashMapUnmanaged(ModuleId, LoadState) = .empty,
    /// Diagnostics from any pass (parse / sema / effects / ownership /
    /// graph load). Per-module diagnostics also live on each module's
    /// sema/effects/ownership checker; the graph keeps a list for
    /// cycle/missing-file errors that don't belong to a single module.
    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ModuleGraph {
        var g: ModuleGraph = .{
            .allocator = allocator,
            .io = io,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        // Sentinel slot 0 = invalid_module.
        g.modules.append(allocator, .{
            .id = invalid_module,
            .path = "",
            .name = "",
            .source = "",
            .p = undefined,
            .ir = .{ .nil = {} },
            .sema = undefined,
            .out_basename = "",
        }) catch {};
        return g;
    }

    pub fn deinit(self: *ModuleGraph) void {
        // Drop sema contexts + parsers for every loaded module.
        for (self.modules.items[1..]) |*m| {
            m.sema.deinit();
            self.allocator.destroy(m.sema);
            m.p.deinit();
            self.allocator.destroy(m.p);
            m.imports.deinit(self.allocator);
        }
        self.modules.deinit(self.allocator);
        self.by_path.deinit(self.allocator);
        self.state.deinit(self.allocator);
        for (self.diagnostics.items) |d| self.allocator.free(d.message);
        self.diagnostics.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const ModuleGraph) bool {
        for (self.diagnostics.items) |_| return true; // any diag is fatal at the graph level
        for (self.modules.items[1..]) |m| {
            if (m.sema.hasErrors()) return true;
        }
        return false;
    }

    /// Load the root file (and recursively all reachable imports) into
    /// the graph. Returns the root's ModuleId. Diagnostics — including
    /// cycle detection, missing files, parse errors, sema/effects/
    /// ownership errors — are accumulated on the graph and on each
    /// module's checkers.
    pub fn loadRoot(self: *ModuleGraph, abs_path: []const u8) Error!ModuleId {
        return try self.loadByPath(abs_path);
    }

    /// Load a module by path. Recursive entry point. Cycles are
    /// detected and reported; diamonds (re-import of an already-
    /// loaded module) return the cached id.
    fn loadByPath(self: *ModuleGraph, path: []const u8) Error!ModuleId {
        // Already loaded?
        if (self.by_path.get(path)) |existing| {
            const st = self.state.get(existing) orelse .done;
            if (st == .visiting) {
                try self.errAt(invalid_module, 0, "cyclic import involving `{s}`", .{path});
                return existing;
            }
            return existing;
        }

        // Read source via the I/O context. Handles relative + absolute
        // paths uniformly through std.Io.Dir.cwd().
        const source = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.arena.allocator(),
            .limited(16 * 1024 * 1024),
        ) catch {
            try self.errAt(invalid_module, 0, "cannot read module `{s}`", .{path});
            return invalid_module;
        };

        // Allocate module slot + mark visiting BEFORE recursing.
        const id: ModuleId = @intCast(self.modules.items.len);
        const owned_path = try self.arena.allocator().dupe(u8, path);
        const owned_name = basenameNoExt(self.arena.allocator(), path) catch path;
        const out_basename = try std.fmt.allocPrint(self.arena.allocator(), "{s}.zig", .{owned_name});

        const p_ptr = try self.allocator.create(parser.Parser);
        p_ptr.* = parser.Parser.init(self.allocator, source);

        try self.modules.append(self.allocator, .{
            .id = id,
            .path = owned_path,
            .name = owned_name,
            .source = source,
            .p = p_ptr,
            .ir = .{ .nil = {} },
            .sema = undefined,
            .out_basename = out_basename,
        });
        try self.by_path.put(self.allocator, owned_path, id);
        try self.state.put(self.allocator, id, .visiting);

        // Parse.
        const ir = p_ptr.parseProgram() catch {
            // Use the parser's own error position for diagnostics.
            try self.errAt(id, 0, "parse error in `{s}`", .{path});
            try self.state.put(self.allocator, id, .done);
            return id;
        };
        self.modules.items[id].ir = ir;

        // Discover imports syntactically + recursively load them.
        try self.collectAndLoadImports(id, ir, path);

        // Sema for this module.
        const sema_ptr = try self.allocator.create(types.SemContext);
        sema_ptr.* = try types.check(self.allocator, source, ir);
        self.modules.items[id].sema = sema_ptr;

        // Effects + ownership.
        var eff = try effects.Checker.initWithSema(self.allocator, source, sema_ptr);
        defer eff.deinit();
        try eff.check(ir);
        // Stream effects diagnostics into the module's sema diagnostics
        // so the unified error path reports them.
        for (eff.diagnostics.items) |d| {
            const owned_msg = try self.allocator.dupe(u8, d.message);
            try sema_ptr.diagnostics.append(self.allocator, .{
                .severity = if (d.severity == .@"error") .@"error" else .note,
                .pos = d.pos,
                .message = owned_msg,
            });
        }

        var checker = try ownership.Checker.initWithSema(self.allocator, source, sema_ptr);
        defer checker.deinit();
        try checker.check(ir);
        for (checker.diagnostics.items) |d| {
            const owned_msg = try self.allocator.dupe(u8, d.message);
            try sema_ptr.diagnostics.append(self.allocator, .{
                .severity = if (d.severity == .@"error") .@"error" else .note,
                .pos = d.pos,
                .message = owned_msg,
            });
        }

        try self.state.put(self.allocator, id, .done);
        return id;
    }

    /// Walk the module's IR for `(use NAME)` declarations, resolve
    /// each to an absolute path in the same directory as the importing
    /// file, recursively load, and append to the module's `imports`
    /// list.
    fn collectAndLoadImports(self: *ModuleGraph, id: ModuleId, ir: parser.Sexp, importer_path: []const u8) Error!void {
        if (ir != .list or ir.list.len == 0 or ir.list[0] != .tag) return;
        if (ir.list[0].tag != .@"module") return;

        const dir = std.fs.path.dirname(importer_path) orelse ".";

        for (ir.list[1..]) |child| {
            if (child != .list or child.list.len < 2 or child.list[0] != .tag) continue;
            if (child.list[0].tag != .@"use") continue;
            if (child.list[1] != .src) continue;

            const m = &self.modules.items[id];
            const local_name = m.source[child.list[1].src.pos..][0..child.list[1].src.len];
            const pos: u32 = child.list[1].src.pos;

            // Skip `use std` — that's the Zig stdlib, not a Rig module.
            if (std.mem.eql(u8, local_name, "std")) continue;

            // Build the candidate path: <importer_dir>/<local_name>.rig.
            const filename = try std.fmt.allocPrint(self.arena.allocator(), "{s}.rig", .{local_name});
            const candidate = try std.fs.path.resolve(self.arena.allocator(), &.{ dir, filename });

            const target_id = try self.loadByPath(candidate);
            if (target_id != invalid_module) {
                try self.modules.items[id].imports.append(self.allocator, .{
                    .local_name = local_name,
                    .target = target_id,
                    .pos = pos,
                });
            }
        }
    }

    /// Iterate every loaded module's diagnostic stream and write to `w`.
    pub fn writeAllDiagnostics(self: *const ModuleGraph, w: anytype) !void {
        // Graph-level diagnostics first (cycles, missing files).
        for (self.diagnostics.items) |d| {
            try w.print("error: {s}\n", .{d.message});
        }
        // Then per-module diagnostics in load order.
        for (self.modules.items[1..]) |m| {
            try m.sema.writeDiagnostics(m.path, w);
        }
    }

    fn errAt(self: *ModuleGraph, module: ModuleId, pos: u32, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.diagnostics.append(self.allocator, .{
            .module = module,
            .pos = pos,
            .message = msg,
        });
    }
};

/// Extract `<basename>` from `<dir>/<basename>.rig`. Returns
/// arena-owned slice. If the path has no `.rig` extension, returns
/// the bare basename.
fn basenameNoExt(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".rig")) base = base[0 .. base.len - 4];
    return try allocator.dupe(u8, base);
}

// =============================================================================
// Tests
// =============================================================================

test "basenameNoExt strips .rig suffix" {
    const allocator = std.testing.allocator;
    const a = try basenameNoExt(allocator, "/foo/bar/baz.rig");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("baz", a);

    const b = try basenameNoExt(allocator, "qux");
    defer allocator.free(b);
    try std.testing.expectEqualStrings("qux", b);
}
