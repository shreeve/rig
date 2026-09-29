//! Module graph: loads a program and the modules it `use`s, and runs
//! every checker on each.
//!
//!   use foo          # loads foo.rig from the root file's directory
//!   use foo as f     # the same module, named `f` here
//!   use std.os       # the standard library's `os`, named `os` here
//!   foo.bar(...)     # qualified access to foo's `pub` declarations
//!
//! A program lives in one directory, the root file's: `use foo` names
//! `foo.rig` there whichever module says it, and the file's real name
//! must be exactly `foo.rig` (not a symlink under another name, nor
//! another spelling on a case-insensitive filesystem). `use std.NAME`
//! names the standard library's `NAME.rig`, embedded in the compiler
//! (`std/` in the repository), or read from `$RIG_STD` when that is
//! set. A module is keyed by its qualified name (`foo`, `std.os`), so a
//! name denotes one file, and each module emits to its own file in one
//! output directory: `<name>.zig`, or `__rig_std_<name>.zig` for the
//! standard library's. The root emits to `root_zig`, a name no module
//! can have.
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
const std_lib = @import("rig_std");

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

pub const Shim = struct { name: []const u8, source: []const u8 };

pub const Module = struct {
    /// 1-based; also the module's identity for cross-module nominal sema.
    id: ModuleId,
    /// Real absolute path (see `realPath`): the graph's dedup key.
    path: []const u8,
    /// The path as written by the user (or derived from the root's),
    /// used in diagnostics.
    display: []const u8,
    /// The qualified name other modules `use`: the basename without
    /// `.rig`, or `std.NAME` for the standard library's.
    name: []const u8,
    /// Emitted file name: `<name>.zig`, `__rig_std_<name>.zig`, or
    /// `root_zig`.
    out_basename: []const u8,
    /// A module of the standard library.
    is_std: bool = false,
    /// The Zig files its `extern zig` blocks name (standard library
    /// modules only), which the package holds as `rig/std/<name>`.
    shims: std.ArrayListUnmanaged(Shim) = .empty,
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
    /// `$RIG_STD`: the standard library's directory, in place of the
    /// copy embedded in the compiler.
    std_dir: ?[]const u8 = null,
    /// Every module's context by id, which each context shares. Allocated
    /// with the first module, so it stays put when the graph is moved.
    semas: ?*sema.ModuleMap = null,
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
            m.shims.deinit(self.allocator);
        }
        self.modules.deinit(self.allocator);
        self.by_path.deinit(self.allocator);
        self.by_name.deinit(self.allocator);
        if (self.semas) |s| s.deinit(self.allocator);
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

    /// Resolve `use NAME` or `use std.NAME` in module `id`: record the
    /// import, adding the module to the graph if it is new, or report why
    /// it cannot be imported.
    fn resolveUse(self: *ModuleGraph, id: ModuleId, decl: parser.Sexp) Error!union(enum) { failed, loaded, added: ModuleId } {
        const a = self.arena.allocator();
        const importer = self.get(id);
        const path = ir.Use.name(decl);
        const in_std = path.isKind(.member);
        const name_node = if (in_std) ir.Member.name(path) else path;
        const name = name_node.getText(importer.source);
        const alias = ir.Use.alias(decl);
        const local_name = if (alias == .nil) name else alias.getText(importer.source);
        const at = importer.parser.span(decl);

        if (in_std) {
            const head = ir.Member.object(path).getText(importer.source);
            if (!std.mem.eql(u8, head, "std")) {
                try self.errorAt(id, importer.parser.span(path), "`{s}.{s}` names no module: a dotted path names a module of the standard library, `std.{s}`, and a module beside this one is `use {s}`", .{ head, name, name, name });
                return .failed;
            }
        }
        if (std.mem.startsWith(u8, name, reserved_prefix)) {
            try self.errorAt(id, at, "module names starting with `{s}` are reserved for the compiler", .{reserved_prefix});
            return .failed;
        }
        // The standard library is self-contained: it never reaches a
        // program's files, whatever their names.
        if (importer.is_std and !in_std) {
            try self.errorAt(id, at, "a module of the standard library imports only other modules of it: `use std.{s}`", .{name});
            return .failed;
        }
        const qualified = if (in_std) try std.fmt.allocPrint(a, "std.{s}", .{name}) else name;
        const target = self.by_name.get(qualified) orelse blk: {
            const file = try std.fmt.allocPrint(a, "{s}.rig", .{name});
            if (in_std) {
                const found = self.readStd(file) catch |err| {
                    try self.stdError(id, at, file, err);
                    return .failed;
                } orelse {
                    try self.errorAt(id, at, "the standard library has no module `{s}`", .{name});
                    return .failed;
                };
                const added = try self.add(found.key, found.display, qualified, found.source);
                self.get(added).is_std = true;
                self.get(added).out_basename = try std.fmt.allocPrint(a, "__rig_std_{s}.zig", .{name});
                if (!try self.loadShims(added)) self.get(added).state = .failed;
                try self.get(id).imports.append(self.allocator, .{ .local_name = local_name, .target = added });
                return .{ .added = added };
            }
            const display = if (std.fs.path.dirname(self.root().display)) |d| try std.fs.path.join(a, &.{ d, file }) else file;
            const source = self.read(display) catch |err| {
                const hint = if (std.mem.eql(u8, name, "std")) "; a module of the standard library is `use std.NAME`" else "";
                try self.errorAt(id, at, "cannot read module `{s}` ({s}): {s}{s}", .{ name, display, fileError(err), hint });
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
            try self.get(id).imports.append(self.allocator, .{ .local_name = local_name, .target = added });
            return .{ .added = added };
        };
        if (self.get(target).state == .loading) {
            try self.errorAt(id, at, "cyclic import: `{s}` is still being loaded when `{s}` imports it", .{ qualified, self.get(id).name });
            return .failed;
        }
        for (self.get(id).imports.items) |imp| if (imp.target == target and std.mem.eql(u8, imp.local_name, local_name)) {
            try self.errorAt(id, at, "`{s}` is already imported as `{s}`", .{ qualified, local_name });
            return .failed;
        };
        try self.get(id).imports.append(self.allocator, .{ .local_name = local_name, .target = target });
        return .loaded;
    }

    /// Read the Zig file of each `extern zig` block of the standard
    /// library's module `id`; false if one cannot be.
    fn loadShims(self: *ModuleGraph, id: ModuleId) Error!bool {
        const m = self.get(id);
        if (m.ir == .nil) return true;
        for (ir.Module.decls(m.ir)) |decl| {
            if (!decl.isKind(.zig_extern)) continue;
            const leaf = ir.ZigExtern.file(decl);
            const at = m.parser.span(leaf);
            const quoted = leaf.getText(m.source);
            const file = quoted[1 .. quoted.len - 1];
            const base = file[0 .. file.len -| 4];
            const plain = std.mem.endsWith(u8, file, ".zig") and base.len > 0 and for (base) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '_') break false;
            } else true;
            if (!plain) {
                try self.errorAt(id, at, "`extern zig` names a Zig file of the standard library, `name.zig`", .{});
                return false;
            }
            const found = self.readStd(file) catch |err| {
                try self.stdError(id, at, file, err);
                return false;
            } orelse {
                try self.errorAt(id, at, "the standard library has no Zig file `{s}`", .{file});
                return false;
            };
            try self.get(id).shims.append(self.allocator, .{ .name = file, .source = found.source });
        }
        return true;
    }

    /// A file of the standard library: from `$RIG_STD` when it is set,
    /// else embedded in the compiler (null when there is no such file).
    /// `key` identifies the file in the graph, apart from every file of
    /// the program, even when `$RIG_STD` names the program's directory:
    /// a module is the standard library's or the program's, never both.
    /// `display` names it in diagnostics.
    fn readStd(self: *ModuleGraph, file: []const u8) !?struct { key: []const u8, display: []const u8, source: []const u8 } {
        const a = self.arena.allocator();
        const key = try std.fmt.allocPrint(a, "<std>/{s}", .{file});
        const dir = self.std_dir orelse {
            const source = std_lib.get(file) orelse return null;
            return .{ .key = key, .display = try std.fs.path.join(a, &.{ "std", file }), .source = source };
        };
        const path = try std.fs.path.join(a, &.{ dir, file });
        const source = self.read(path) catch |err| switch (err) {
            error.FileNotFound => {
                var d = std.Io.Dir.cwd().openDir(self.io, dir, .{}) catch return error.NoStdDir;
                d.close(self.io);
                return null;
            },
            else => |e| return e,
        };
        return .{ .key = key, .display = path, .source = source };
    }

    /// Why a file of the standard library named `$RIG_STD` cannot be read.
    fn stdError(self: *ModuleGraph, id: ModuleId, at: parser.Span, file: []const u8, err: anyerror) Error!void {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const dir = self.std_dir.?;
        if (err == error.NoStdDir) return self.errorAt(id, at, "RIG_STD names `{s}`, which is not a directory", .{dir});
        try self.errorAt(id, at, "cannot read `{s}/{s}` (RIG_STD): {s}", .{ dir, file, fileError(err) });
    }

    /// Add a module and parse it; a module that does not parse is
    /// `failed` at once.
    fn add(self: *ModuleGraph, canonical: []const u8, display: []const u8, name: []const u8, source: []const u8) Error!ModuleId {
        const a = self.arena.allocator();
        const id: ModuleId = @intCast(self.modules.items.len + 1);
        const p = blk: {
            // Everything that can fail comes first; the graph owns the
            // module once it is registered.
            const out_basename = if (id == 1) root_zig else try std.fmt.allocPrint(a, "{s}.zig", .{name});
            const semas = self.semas orelse semas: {
                const map = try a.create(sema.ModuleMap);
                map.* = .empty;
                self.semas = map;
                break :semas map;
            };
            try self.modules.ensureUnusedCapacity(self.allocator, 1);
            try self.by_path.ensureUnusedCapacity(self.allocator, 1);
            try self.by_name.ensureUnusedCapacity(self.allocator, 1);
            try semas.ensureUnusedCapacity(self.allocator, 1);
            const ctx = try self.allocator.create(sema.SemContext);
            errdefer self.allocator.destroy(ctx);
            ctx.* = try sema.SemContext.init(self.allocator, source);
            errdefer ctx.deinit();
            const p = try self.allocator.create(parser.Parser);
            p.* = parser.Parser.init(self.allocator, source);

            self.modules.appendAssumeCapacity(.{
                .id = id,
                .path = canonical,
                .display = display,
                .name = name,
                .out_basename = out_basename,
                .source = source,
                .parser = p,
                .sema = ctx,
            });
            self.by_path.putAssumeCapacity(canonical, id);
            self.by_name.putAssumeCapacity(name, id);
            semas.putAssumeCapacity(id, ctx);
            break :blk p;
        };

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

        m.sema.deinit();
        m.sema.* = try sema.check(self.allocator, m.source, m.ir, .{
            .parser = m.parser,
            .imports = entries.items,
            .modules = self.semas.?,
            .name = m.name,
            .module_id = id,
            .is_root = id == 1,
            .zig_file = m.out_basename,
            .is_std = m.is_std,
        });

        // Ownership reads the types sema settled, so a module whose types
        // are wrong is not checked for ownership: its errors would follow
        // from the type errors, or be about code that means nothing yet.
        if (hasTypeErrors(m.sema.diagnostics.items)) {
            m.state = .failed;
            return;
        }
        var own = try ownership.Checker.initWithSema(self.allocator, m.source, m.sema);
        defer own.deinit();
        try own.check(m.ir);
        for (own.diagnostics.items) |d| try self.addDiagnostic(id, d);
        // What the generic bodies copy, for the modules that import them.
        try m.sema.plain_reqs.appendSlice(self.allocator, own.ownPlainReqs());

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
        try m.sema.diagnostics.append(self.allocator, .{ .severity = d.severity, .pos = d.pos, .end = d.end, .message = owned, .module = d.module });
    }

    /// Write every diagnostic, as `path:line:col: error: message`, up to
    /// `diag.max_errors` errors. A note about another module's code
    /// names that module's file.
    pub fn writeAllDiagnostics(self: *const ModuleGraph, w: *std.Io.Writer) !void {
        for (self.errors.items) |message| try w.print("error: {s}\n", .{message});
        const files = try self.allocator.alloc(diag.File, self.modules.items.len);
        defer self.allocator.free(files);
        for (self.modules.items, files) |m, *f| f.* = .{ .source = m.source, .path = m.display };
        var budget: u32 = diag.max_errors;
        var hidden: u32 = 0;
        for (self.modules.items, files) |m, home| hidden += try diag.writeSome(m.sema.diagnostics.items, home, files, w, &budget);
        if (hidden > 0) try w.print("{d} more error{s} not shown\n", .{ hidden, if (hidden == 1) "" else "s" });
    }
};

/// Whether sema reported an error other than a local that is never
/// read: that one is a lint on well-typed code, and the ownership errors
/// of the same program are still worth reporting.
fn hasTypeErrors(items: []const diag.Diagnostic) bool {
    for (items) |d| {
        if (d.severity == .@"error" and !d.lint) return true;
    }
    return false;
}

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
        error.StreamTooLong => std.fmt.comptimePrint("the file is larger than {d} MiB", .{max_source_bytes >> 20}),
        else => @errorName(err),
    };
}

test "moduleName strips the directory and .rig" {
    try std.testing.expectEqualStrings("baz", moduleName("/foo/bar/baz.rig"));
}
