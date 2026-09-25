//! Module graph: loads a program and the modules it `use`s, and runs
//! every checker on each.
//!
//!   use foo          # loads foo.rig from the root file's directory
//!   foo.bar(...)     # qualified access to foo's `pub` declarations
//!
//! A program lives in one directory, the root file's: `use foo` names
//! `foo.rig` there whichever module says it, and the file's real name
//! must be exactly `foo.rig` (not a symlink under another name, nor
//! another spelling on a case-insensitive filesystem). So a module name
//! denotes one file, and each module emits to `<name>.zig` in one output
//! directory. The root emits to `root_zig`, a name no module can have.
//!
//! A module is checked after its imports. A cycle or a module that
//! cannot be read is reported at the `use`. A module whose import has
//! errors is not checked (its errors would only be consequences); the
//! import's own errors are reported.

const std = @import("std");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const ownership = @import("ownership.zig");
const diag = @import("diag.zig");
const ir = parser.ir;

pub const max_source_bytes = 16 * 1024 * 1024;

/// The root module's emitted file. Names starting with `__rig` are the
/// emitter's, and `use` rejects them.
pub const root_zig = "__rig_main.zig";
const reserved_prefix = "__rig";

pub const ModuleId = u32;

pub const Import = struct {
    local_name: []const u8,
    target: ModuleId,
};

pub const Module = struct {
    /// 1-based; also the module's identity for cross-module nominal sema.
    id: ModuleId,
    /// Real absolute path (see `realPath`): the graph's dedup key.
    path: []const u8,
    /// The path as written by the user (or derived from the root's),
    /// used in diagnostics.
    display: []const u8,
    /// Basename without `.rig`: the name other modules `use`.
    name: []const u8,
    /// Emitted file name: `<name>.zig`, or `root_zig`.
    out_basename: []const u8,
    source: []const u8,
    parser: *parser.Parser,
    /// Semantic IR; `.nil` if parsing failed.
    ir: parser.Sexp = .nil,
    /// Always valid, so diagnostics (including parse and import errors)
    /// can be recorded against the module's source.
    sema: *sema.SemContext,
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
    by_name: std.StringHashMapUnmanaged(ModuleId) = .empty,
    /// Errors with no source position (the root file cannot be read).
    errors: std.ArrayListUnmanaged([]const u8) = .empty,

    pub const Error = std.mem.Allocator.Error;

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
        self.by_name.deinit(self.allocator);
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
    ///
    /// Loading walks the `use` declarations depth first with an explicit
    /// stack, so an import chain of any depth fits. A module is checked
    /// when it leaves the stack, after all of its imports; while on the
    /// stack it is `loading`, which is how a cycle is recognized.
    pub fn loadRoot(self: *ModuleGraph, path: []const u8) Error!void {
        const source = self.read(path) catch |err| {
            try self.errors.append(self.allocator, try std.fmt.allocPrint(self.arena.allocator(), "cannot read `{s}`: {s}", .{ path, fileError(err) }));
            return;
        };
        const Frame = struct { id: ModuleId, next: usize = 0, ok: bool = true };
        var stack: std.ArrayListUnmanaged(Frame) = .empty;
        defer stack.deinit(self.allocator);

        const root_id = try self.add(try self.realPath(path), path, moduleName(path), source);
        if (self.get(root_id).state == .loading) try stack.append(self.allocator, .{ .id = root_id });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const decls = ir.Module.decls(self.get(top.id).ir);
            if (top.next < decls.len) {
                const decl = decls[top.next];
                top.next += 1;
                if (!decl.isKind(.use)) continue;
                switch (try self.resolveUse(top.id, decl)) {
                    .failed => top.ok = false,
                    .loaded => {},
                    .added => |id| if (self.get(id).state == .loading) try stack.append(self.allocator, .{ .id = id }),
                }
                continue;
            }
            const done = stack.pop().?;
            const m = self.get(done.id);
            const imports_checked = for (m.imports.items) |imp| {
                if (self.get(imp.target).state != .checked) break false;
            } else true;
            if (done.ok and imports_checked) try self.check(done.id) else m.state = .failed;
        }
    }

    /// Resolve `use NAME` in module `id`: record the import, adding the
    /// module to the graph if it is new, or report why it cannot be
    /// imported.
    fn resolveUse(self: *ModuleGraph, id: ModuleId, decl: parser.Sexp) Error!union(enum) { failed, loaded, added: ModuleId } {
        const a = self.arena.allocator();
        const importer = self.get(id);
        const name_node = ir.Use.name(decl);
        const name = importer.source[name_node.src.pos..][0..name_node.src.len];
        const at = importer.parser.span(decl);

        if (std.mem.startsWith(u8, name, reserved_prefix)) {
            try self.errorAt(id, at, "module names starting with `{s}` are reserved for the compiler", .{reserved_prefix});
            return .failed;
        }
        const target = self.by_name.get(name) orelse blk: {
            const file = try std.fmt.allocPrint(a, "{s}.rig", .{name});
            const display = if (std.fs.path.dirname(self.root().display)) |d| try std.fs.path.join(a, &.{ d, file }) else file;
            const source = self.read(display) catch |err| {
                try self.errorAt(id, at, "cannot read module `{s}` ({s}): {s}", .{ name, display, fileError(err) });
                return .failed;
            };
            const canonical = try self.realPath(display);
            const real = std.fs.path.basename(canonical);
            if (!std.mem.eql(u8, real, file)) {
                try self.errorAt(id, at, "module `{s}` is the file `{s}`; import it by that name", .{ name, real });
                return .failed;
            }
            if (self.by_path.get(canonical)) |existing| break :blk existing;
            const added = try self.add(canonical, display, name, source);
            try self.get(id).imports.append(self.allocator, .{ .local_name = name, .target = added });
            return .{ .added = added };
        };
        if (self.get(target).state == .loading) {
            try self.errorAt(id, at, "cyclic import: `{s}` is still being loaded when `{s}` imports it", .{ name, self.get(id).name });
            return .failed;
        }
        try self.get(id).imports.append(self.allocator, .{ .local_name = name, .target = target });
        return .loaded;
    }

    /// Add a module and parse it; a module that does not parse is
    /// `failed` at once.
    fn add(self: *ModuleGraph, canonical: []const u8, display: []const u8, name: []const u8, source: []const u8) Error!ModuleId {
        const a = self.arena.allocator();
        const ctx = try self.allocator.create(sema.SemContext);
        errdefer self.allocator.destroy(ctx);
        ctx.* = try sema.SemContext.init(self.allocator, source);
        const p = try self.allocator.create(parser.Parser);
        p.* = parser.Parser.init(self.allocator, source);

        const id: ModuleId = @intCast(self.modules.items.len + 1);
        try self.modules.append(self.allocator, .{
            .id = id,
            .path = canonical,
            .display = display,
            .name = name,
            .out_basename = if (id == 1) root_zig else try std.fmt.allocPrint(a, "{s}.zig", .{name}),
            .source = source,
            .parser = p,
            .sema = ctx,
        });
        try self.by_path.put(self.allocator, canonical, id);
        try self.by_name.put(self.allocator, name, id);

        self.get(id).ir = p.parseProgram() catch |err| switch (err) {
            error.ParseError => {
                const d = p.diagnostic();
                try self.errorAt(id, .{ .start = d.pos, .end = d.end }, "{s}", .{d.message});
                if (p.unclosedBracket()) |note| try self.get(id).sema.diagnostics.append(self.allocator, note);
                self.get(id).state = .failed;
                return id;
            },
            error.InputTooLarge => unreachable, // sources are at most `max_source_bytes`
            else => |e| return e,
        };
        return id;
    }

    fn read(self: *ModuleGraph, path: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.arena.allocator(), .limited(max_source_bytes));
    }

    /// The real absolute path of a readable file, or, where the platform
    /// cannot tell (Linux without /proc), the path as resolved lexically.
    fn realPath(self: *ModuleGraph, path: []const u8) Error![]const u8 {
        const a = self.arena.allocator();
        return std.Io.Dir.cwd().realPathFileAlloc(self.io, path, a) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => std.fs.path.resolve(a, &.{path}),
        };
    }

    /// Run sema and ownership on a parsed module whose imports are all
    /// checked.
    fn check(self: *ModuleGraph, id: ModuleId) Error!void {
        const m = self.get(id);
        var entries: std.ArrayListUnmanaged(sema.ImportEntry) = .empty;
        defer entries.deinit(self.allocator);
        for (m.imports.items) |imp| {
            try entries.append(self.allocator, .{ .local_name = imp.local_name, .sema = self.get(imp.target).sema, .module_id = imp.target });
        }

        // Modules the imports reach in turn.
        var reached: std.ArrayListUnmanaged(sema.ImportEntry) = .empty;
        defer reached.deinit(self.allocator);
        var seen = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.modules.items.len + 1);
        defer seen.deinit(self.allocator);
        var work: std.ArrayListUnmanaged(ModuleId) = .empty;
        defer work.deinit(self.allocator);
        seen.set(id);
        for (m.imports.items) |imp| {
            seen.set(imp.target);
            try work.append(self.allocator, imp.target);
        }
        while (work.pop()) |mid| {
            for (self.get(mid).imports.items) |imp| {
                if (seen.isSet(imp.target)) continue;
                seen.set(imp.target);
                const t = self.get(imp.target);
                try reached.append(self.allocator, .{ .local_name = t.name, .sema = t.sema, .module_id = imp.target });
                try work.append(self.allocator, imp.target);
            }
        }

        m.sema.deinit();
        m.sema.* = try sema.checkWithImports(self.allocator, m.source, m.parser, m.ir, entries.items, reached.items, id);

        var own = try ownership.Checker.initWithSema(self.allocator, m.source, m.sema);
        defer own.deinit();
        try own.check(m.ir);
        for (own.diagnostics.items) |d| try self.addDiagnostic(id, d);

        m.state = if (m.sema.hasErrors()) .failed else .checked;
    }

    fn errorAt(self: *ModuleGraph, id: ModuleId, at: parser.Span, comptime fmt: []const u8, args: anytype) Error!void {
        const m = self.get(id);
        const message = try std.fmt.allocPrint(m.sema.arena.allocator(), fmt, args);
        try m.sema.diagnostics.append(self.allocator, .{ .severity = .@"error", .pos = at.start, .end = at.end, .message = message });
    }

    fn addDiagnostic(self: *ModuleGraph, id: ModuleId, d: sema.Diagnostic) Error!void {
        const m = self.get(id);
        const owned = try m.sema.arena.allocator().dupe(u8, d.message);
        try m.sema.diagnostics.append(self.allocator, .{ .severity = d.severity, .pos = d.pos, .end = d.end, .message = owned });
    }

    /// Write every diagnostic, as `path:line:col: error: message`, up to
    /// `diag.max_errors` errors.
    pub fn writeAllDiagnostics(self: *const ModuleGraph, w: *std.Io.Writer) !void {
        for (self.errors.items) |message| try w.print("error: {s}\n", .{message});
        var budget: u32 = diag.max_errors;
        var hidden: u32 = 0;
        for (self.modules.items) |m| hidden += try diag.writeSome(m.sema.diagnostics.items, m.source, m.display, w, &budget);
        if (hidden > 0) try w.print("{d} more error{s} not shown\n", .{ hidden, if (hidden == 1) "" else "s" });
    }
};

/// `dir/name.rig` → `name`.
fn moduleName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (std.mem.endsWith(u8, base, ".rig")) base[0 .. base.len - 4] else base;
}

/// Why a source file cannot be read, as a reader would say it.
pub fn fileError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file",
        error.IsDir => "it is a directory",
        error.NotDir => "a component of the path is not a directory",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.StreamTooLong => "the file is larger than 16 MiB",
        else => @errorName(err),
    };
}

test "moduleName strips the directory and .rig" {
    try std.testing.expectEqualStrings("baz", moduleName("/foo/bar/baz.rig"));
}
