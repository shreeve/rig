//! Module graph: loads a program and the modules it `use`s, and runs
//! every checker on each.
//!
//!   use foo          # foo.rig, or the directory foo/, in the root's directory
//!   use foo as f     # the same module, named `f` here
//!   use foo.bar      # the directory foo/bar/, named `bar` here
//!   use std.os       # the standard library's `os`, named `os` here
//!   foo.bar(...)     # qualified access to foo's `pub` declarations
//!
//! A program lives in one directory, the root file's, and a module path
//! names a file or directory from there, whichever module says it:
//! `use foo` names `foo.rig` or the directory `foo/` (not both), and
//! `use a.b.c` the directory `a/b/c/`. Every `.rig` file in a directory
//! belongs to that directory's module, so a module beneath another is a
//! directory too. Each name of a path is spelled as on disk (not through
//! a symlink under another name, nor in another case on a
//! case-insensitive filesystem). `use std.PATH` names the standard
//! library's module by the same rule, from its files embedded in the
//! compiler (`std/` in the repository), or from `$RIG_STD` when that is
//! set. A module is keyed by its qualified name (`foo`, `a.b.c`,
//! `std.os`), so a name denotes one module, and each module emits to its
//! own file in one output directory: `<name>.zig`, or
//! `__rig_std_<name>.zig` for the standard library's. The root emits to
//! `root_zig`, a name no module can have.
//!
//! A directory module is the one-file module whose source is its files
//! joined in the byte order of their names (docs/INTERNALS.md,
//! "Directory modules"): each file closes its own blocks and brackets, a
//! diagnostic names the file it is in, and a `use` binds its name in its
//! own file only. Its files whose names end in `_test.rig` belong to it
//! only when it is the root of a build for `rig test`: the root may be a
//! directory, and no imported module has its test files.
//!
//! A module is checked after its imports, so modules may not import
//! each other in a cycle. A cycle or a module that cannot be read is
//! reported at the `use`. A module whose import has errors is not
//! checked (its errors would only be consequences); the import's own
//! errors are reported.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const sema = @import("sema.zig");
const proofs = @import("proofs.zig");
const ownership = @import("ownership.zig");
const diag = @import("diag.zig");
const timing = @import("timing.zig");
const ir = parser.ir;
const std_lib = @import("rig_std");

/// The most bytes a source file holds (16 MiB).
pub const max_source_bytes = 16 * 1024 * 1024;

/// The root module's emitted file. Names starting with `__rig` are the
/// emitter's, and `use` rejects them.
pub const root_zig = "__rig_main.zig";
const reserved_prefix = "__rig";

pub const ModuleId = u32;

pub const Import = struct {
    local_name: []const u8,
    target: ModuleId,
    /// The file of a directory module whose `use` binds it
    /// (`Module.parts`); 0 for a module of one file.
    file: u32 = 0,
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
    shims: std.ArrayList(Shim) = .empty,
    source: []const u8,
    /// A directory module: where each of its files starts in `source`,
    /// and its path. Empty for a module of one file.
    parts: []const diag.Part = &.{},
    parser: *parser.Parser,
    /// Semantic IR; `.nil` if parsing failed.
    ir: parser.Sexp = .nil,
    /// Always valid, so diagnostics (including parse and import errors)
    /// can be recorded against the module's source.
    sema: *sema.SemContext,
    imports: std.ArrayList(Import) = .empty,
    state: State = .loading,
    /// Whether the ownership checker ran on the module, and the range of
    /// `sema.diagnostics` it appended (read by test tools).
    own_ran: bool = false,
    own_diags: [2]u32 = .{ 0, 0 },

    pub const State = enum { loading, checked, failed };
};

pub const ModuleGraph = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    /// Modules in load order; the root is first.
    modules: std.ArrayList(Module) = .empty,
    by_path: std.StringHashMapUnmanaged(ModuleId) = .empty,
    by_name: std.StringHashMapUnmanaged(ModuleId) = .empty,
    /// `$RIG_STD`: the standard library's directory, in place of the
    /// copy embedded in the compiler.
    std_dir: ?[]const u8 = null,
    /// Every module's context by id, which each context shares. Allocated
    /// with the first module, so it stays put when the graph is moved.
    semas: ?*sema.ModuleMap = null,
    /// Errors with no source position (the root file cannot be read).
    errors: std.ArrayList([]const u8) = .empty,
    /// Where `rig check --time` adds the time of each pass.
    timing: ?*timing.Timing = null,
    /// The program is built for `rig test`: the root, when it is a
    /// directory module, has its `_test.rig` files. An imported module
    /// never does.
    with_tests: bool = false,
    /// Where the root's imports are: the root file's directory, or a
    /// directory root's parent (null for the current directory).
    import_dir: ?[]const u8 = null,
    /// The root file's text, when the caller holds it (the language
    /// server's open document), read in place of the file. The caller
    /// keeps it alive as long as the graph.
    root_source: ?[]const u8 = null,

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

    /// Marks each plain enum some module calls `from_text` on in the
    /// module that declares it, which emits its table of names
    /// (`sema.SemContext.recordTextTable`). Run once every module is
    /// checked.
    pub fn markTextTables(self: *ModuleGraph) Error!void {
        for (self.modules.items) |m| for (m.sema.foreign_text_tables.items) |ref| {
            const owner = self.get(ref.module_id).sema;
            try owner.text_tables.put(owner.allocator, ref.sym, {});
        };
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
    ///
    /// The root is a file, or a directory module (`isDirectory`), whose
    /// imports are then its siblings.
    pub fn loadRoot(self: *ModuleGraph, path: []const u8) Error!void {
        const Frame = struct { id: ModuleId, next: usize = 0, ok: bool = true };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(self.allocator);

        const root_id = if (self.isDirectory(path)) blk: {
            const shown = std.mem.trimEnd(u8, path, "/");
            const canonical = try self.realPath(path);
            const name = moduleName(canonical);
            const found = (try self.readDir(null, .{ .start = 0, .end = 0 }, .{}, if (shown.len == 0) "/" else shown, name)) orelse return;
            // Siblings are in the real parent. The spelled parent names
            // it unless the path ends in `.` or `..` or goes through a
            // link; then the real parent is used.
            const base = std.fs.path.basename(shown);
            const spelled = std.fs.path.dirname(shown);
            const same = !std.mem.eql(u8, base, ".") and !std.mem.eql(u8, base, "..") and std.mem.eql(u8, std.fs.path.basename(canonical), base) and
                std.mem.eql(u8, try self.realPath(spelled orelse "."), std.fs.path.dirname(canonical) orelse "/");
            self.import_dir = if (same) spelled else std.fs.path.dirname(canonical) orelse "/";
            break :blk try self.add(found.key, found.display, name, found.source, found.parts);
        } else blk: {
            self.import_dir = std.fs.path.dirname(path);
            const source = (if (self.root_source) |text| sized(text) else self.read(path)) catch |err| {
                try self.errors.append(self.allocator, try self.arena.allocator().print("cannot read `{s}`: {s}", .{ path, fileError(err) }));
                return;
            };
            break :blk try self.add(try self.realPath(path), path, moduleName(path), source, &.{});
        };
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

    /// Resolve `use PATH` in module `id`: record the import, adding the
    /// module to the graph if it is new, or report why it cannot be
    /// imported.
    fn resolveUse(self: *ModuleGraph, id: ModuleId, decl: parser.Sexp) Error!union(enum) { failed, loaded, added: ModuleId } {
        const a = self.arena.allocator();
        const importer = self.get(id);
        const path = ir.Use.name(decl);
        var names: std.ArrayList([]const u8) = .empty;
        var node = path;
        while (node.isKind(.member)) : (node = ir.Member.object(node)) try names.append(a, rig.leafText(importer.source, ir.Member.name(node).src));
        try names.append(a, rig.leafText(importer.source, node.src));
        std.mem.reverse([]const u8, names.items);
        const in_std = names.items.len > 1 and std.mem.eql(u8, names.items[0], "std");
        const comps = if (in_std) names.items[1..] else names.items;
        const name = comps[comps.len - 1];
        const alias = ir.Use.alias(decl);
        const local_name = if (alias == .nil) name else rig.leafText(importer.source, alias.src);
        const at = importer.parser.span(decl);
        const file = sema.fileIndex(importer.parts, at.start);

        for (comps) |c| if (std.mem.startsWith(u8, c, reserved_prefix)) {
            try self.errorAt(id, at, "module names starting with `{s}` are reserved for the compiler", .{reserved_prefix});
            return .failed;
        };
        const dotted = try std.mem.join(a, ".", comps);
        // The standard library is self-contained: it never reaches a
        // program's files, whatever their names.
        if (importer.is_std and !in_std) {
            try self.errorAt(id, at, "a module of the standard library imports only other modules of it: `use std.{s}`", .{dotted});
            return .failed;
        }
        const qualified = if (in_std) try a.print("std.{s}", .{dotted}) else dotted;
        const target = self.by_name.get(qualified) orelse blk: {
            const tree: Tree = if (!in_std) .{ .dir = self.import_dir } else if (self.std_dir) |d| .{ .dir = d, .std = true } else .{ .std = true, .embedded = true };
            const found = (try self.findModule(id, at, tree, comps, qualified)) orelse return .failed;
            if (self.by_path.get(found.key)) |existing| break :blk existing;
            const added = try self.add(found.key, found.display, qualified, found.source, found.parts);
            if (in_std) {
                self.get(added).is_std = true;
                self.get(added).out_basename = try a.print("__rig_std_{s}.zig", .{dotted});
                if (!try self.loadShims(added)) self.get(added).state = .failed;
            }
            try self.get(id).imports.append(self.allocator, .{ .local_name = local_name, .target = added, .file = file });
            return .{ .added = added };
        };
        if (self.get(target).state == .loading) {
            try self.errorAt(id, at, "cyclic import: `{s}` is still being loaded when `{s}` imports it; modules may not import each other in a cycle: put the files that call each other in one module, a directory", .{ qualified, self.get(id).name });
            return .failed;
        }
        // Each file of a directory module says what it uses.
        for (self.get(id).imports.items) |imp| if (imp.target == target and imp.file == file and std.mem.eql(u8, imp.local_name, local_name)) {
            try self.errorAt(id, at, "`{s}` is already imported as `{s}`", .{ qualified, local_name });
            return .failed;
        };
        try self.get(id).imports.append(self.allocator, .{ .local_name = local_name, .target = target, .file = file });
        return .loaded;
    }

    /// Where a module path's files are: a directory of files (the
    /// program's root directory, or `$RIG_STD`), or the standard
    /// library embedded in the compiler (`dir` null).
    const Tree = struct {
        /// The directory; null for the current one.
        dir: ?[]const u8 = null,
        std: bool = false,
        /// The standard library embedded in the compiler.
        embedded: bool = false,

        /// `rel` under the tree, as a path to open.
        fn path(t: Tree, a: std.mem.Allocator, rel: []const u8) ![]const u8 {
            return if (t.dir) |d| std.fs.path.join(a, &.{ d, rel }) else a.dupe(u8, rel);
        }
    };

    const Found = struct { key: []const u8, display: []const u8, source: []const u8, parts: []const diag.Part };

    const Kind = enum { none, file, dir };

    /// What `rel` is in `tree`.
    fn kindIn(self: *ModuleGraph, tree: Tree, rel: []const u8) Error!Kind {
        if (tree.embedded) {
            if (std_lib.get(rel) != null) return .file;
            for (std_lib.files) |f| if (f[0].len > rel.len and std.mem.startsWith(u8, f[0], rel) and f[0][rel.len] == '/') return .dir;
            return .none;
        }
        const p = try tree.path(self.arena.allocator(), rel);
        const st = std.Io.Dir.cwd().statFile(self.io, p, .{}) catch return .none;
        return if (st.kind == .directory) .dir else .file;
    }

    /// The module `comps` names in `tree`, read and joined; null when
    /// there is none, which is reported at `at` in module `id`.
    fn findModule(self: *ModuleGraph, id: ModuleId, at: parser.Span, tree: Tree, comps: []const []const u8, qualified: []const u8) Error!?Found {
        const a = self.arena.allocator();
        const rel = try std.mem.join(a, "/", comps);
        const file = try a.print("{s}.rig", .{rel});
        if (tree.std and !tree.embedded) {
            var d = std.Io.Dir.cwd().openDir(self.io, tree.dir.?, .{}) catch {
                try self.errorAt(id, at, "RIG_STD names `{s}`, which is not a directory", .{tree.dir.?});
                return null;
            };
            d.close(self.io);
        }
        const dir_kind = try self.kindIn(tree, rel);
        const file_kind = try self.kindIn(tree, file);
        if (comps.len > 1 and dir_kind != .dir) {
            const parent = try std.mem.join(a, "/", comps[0 .. comps.len - 1]);
            const shown = if (tree.std) try a.print("std.{s}", .{try std.mem.join(a, ".", comps[0 .. comps.len - 1])}) else try std.mem.join(a, ".", comps[0 .. comps.len - 1]);
            if (file_kind == .file) {
                try self.errorAt(id, at, "`{s}` is part of module `{s}`; a module under `{s}/` is a directory, such as `{s}/`", .{ file, shown, parent, rel });
            } else if (tree.std) {
                try self.errorAt(id, at, "the standard library has no module `{s}`: no directory {s}/", .{ qualified, rel });
            } else try self.errorAt(id, at, "cannot read module `{s}`: no directory {s}/", .{ qualified, rel });
            return null;
        }
        if (comps.len == 1 and dir_kind == .dir and file_kind != .none) {
            try self.errorAt(id, at, "module `{s}` is both the file `{s}` and the directory `{s}/`; keep one", .{ qualified, file, rel });
            return null;
        }
        if (dir_kind == .dir) return self.readDir(id, at, tree, rel, qualified);
        if (tree.std) {
            const found = self.readStd(file) catch |err| {
                try self.stdError(id, at, file, err);
                return null;
            } orelse {
                try self.errorAt(id, at, "the standard library has no module `{s}`", .{comps[0]});
                return null;
            };
            return .{ .key = found.key, .display = found.display, .source = found.source, .parts = &.{} };
        }
        const name = comps[0];
        const display = try tree.path(a, file);
        const source = self.read(display) catch |err| {
            const hint = if (std.mem.eql(u8, name, "std")) "; a module of the standard library is `use std.NAME`" else "";
            try self.errorAt(id, at, "cannot read module `{s}` ({s}): {s}{s}", .{ name, display, fileError(err), hint });
            return null;
        };
        const canonical = try self.realPath(display);
        const real = std.fs.path.basename(canonical);
        if (!std.mem.eql(u8, real, file)) {
            try self.errorAt(id, at, "module `{s}` is the file `{s}`; import it by that name", .{ name, real });
            return null;
        }
        return .{ .key = canonical, .display = display, .source = source, .parts = &.{} };
    }

    /// The directory module at `rel` in `tree`: its `.rig` files, in the
    /// byte order of their names, joined into one source, each ending in
    /// a newline and without a byte order mark. `id` is the importing
    /// module, null for the root, the only directory module that has its
    /// test files, and only under `with_tests`.
    fn readDir(self: *ModuleGraph, id: ?ModuleId, at: parser.Span, tree: Tree, rel: []const u8, qualified: []const u8) Error!?Found {
        const a = self.arena.allocator();
        const own_tests = id == null and self.with_tests;
        const display_dir = if (tree.embedded) try a.print("std/{s}/", .{rel}) else try a.print("{s}/", .{try tree.path(a, rel)});
        var key: []const u8 = try a.print("<std>/{s}/", .{rel});
        var names: std.ArrayList([]const u8) = .empty;
        if (tree.embedded) {
            for (std_lib.files) |f| {
                const n = f[0];
                if (n.len > rel.len + 1 and std.mem.startsWith(u8, n, rel) and n[rel.len] == '/' and std.mem.findScalar(u8, n[rel.len + 1 ..], '/') == null) {
                    if (belongs(n[rel.len + 1 ..], false)) try names.append(a, n[rel.len + 1 ..]);
                }
            }
        } else {
            const dir_path = try tree.path(a, rel);
            if (!tree.std) {
                // Each name of the path is spelled as on disk.
                const canonical = try self.realPath(dir_path);
                var parts = std.mem.splitBackwardsScalar(u8, canonical, std.fs.path.sep);
                var comps = std.mem.splitBackwardsScalar(u8, rel, '/');
                var wrong = false;
                while (comps.next()) |c| if (!std.mem.eql(u8, parts.next() orelse "", c)) {
                    wrong = true;
                };
                if (wrong and id != null) {
                    const n = std.mem.countScalar(u8, rel, '/') + 1;
                    var start = canonical.len;
                    var seen: usize = 0;
                    while (start > 0 and seen < n) : (start -= 1) {
                        if (canonical[start - 1] == std.fs.path.sep) seen += 1;
                        if (seen == n) break;
                    }
                    try self.dirError(id, at, "module `{s}` is the directory `{s}/`; import it by that name", .{ qualified, canonical[start..] });
                    return null;
                }
                key = try a.print("{s}/", .{canonical});
            }
            var d = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch |err| {
                try self.dirError(id, at, "cannot read module `{s}` ({s}): {s}", .{ qualified, display_dir, fileError(err) });
                return null;
            };
            defer d.close(self.io);
            var it = d.iterate();
            while (it.next(self.io) catch |err| {
                try self.dirError(id, at, "cannot read module `{s}` ({s}): {s}", .{ qualified, display_dir, fileError(err) });
                return null;
            }) |entry| {
                if (!std.mem.endsWith(u8, entry.name, ".rig") or entry.name.len == 4 or !belongs(entry.name, own_tests)) continue;
                const st = d.statFile(self.io, entry.name, .{}) catch continue;
                if (st.kind != .file) continue;
                try names.append(a, try a.dupe(u8, entry.name));
            }
        }
        if (names.items.len == 0) {
            if (id == null) try self.dirError(id, at, "the directory `{s}` holds no `.rig` file", .{display_dir}) else try self.dirError(id, at, "module `{s}` is the directory `{s}`, which holds no `.rig` file", .{ qualified, display_dir });
            return null;
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        var joined: std.ArrayList(u8) = .empty;
        var parts: std.ArrayList(diag.Part) = .empty;
        for (names.items) |n| {
            const shown = try a.print("{s}{s}", .{ display_dir, n });
            const text = if (tree.embedded) std_lib.get(try a.print("{s}/{s}", .{ rel, n })).? else self.read(shown) catch |err| {
                try self.dirError(id, at, "cannot read `{s}`: {s}", .{ shown, fileError(err) });
                return null;
            };
            const body = if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text;
            const newline: usize = @intFromBool(body.len > 0 and body[body.len - 1] != '\n');
            if (joined.items.len + body.len + newline > max_source_bytes) {
                try self.dirError(id, at, "module `{s}` is larger than {d} MiB, the most one module may hold; split it into modules", .{ qualified, max_source_bytes >> 20 });
                return null;
            }
            try parts.append(a, .{ .start = @intCast(joined.items.len), .path = shown });
            try joined.appendSlice(a, body);
            if (newline == 1) try joined.append(a, '\n');
        }
        return .{ .key = key, .display = display_dir, .source = joined.items, .parts = parts.items };
    }

    /// An error in reading a directory module: at the `use` of module
    /// `id`, or, for the root, with no position.
    fn dirError(self: *ModuleGraph, id: ?ModuleId, at: parser.Span, comptime fmt: []const u8, args: anytype) Error!void {
        if (id) |i| return self.errorAt(i, at, fmt, args);
        try self.errors.append(self.allocator, try self.arena.allocator().print(fmt, args));
    }

    /// Whether `path` is a directory, which as a root is a directory
    /// module.
    fn isDirectory(self: *ModuleGraph, path: []const u8) bool {
        const st = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
        return st.kind == .directory;
    }

    /// Whether a file of a directory belongs to its module: a test file,
    /// `name_test.rig`, only for the root of a build for `rig test`.
    fn belongs(name: []const u8, own_tests: bool) bool {
        return std.mem.endsWith(u8, name, ".rig") and (own_tests or !std.mem.endsWith(u8, name, "_test.rig"));
    }

    /// Read the Zig file of each `extern zig` block of the standard
    /// library's module `id`, and each Zig file of the standard library
    /// those import by its plain name (`@import("name.zig")`), which the
    /// package holds beside them; false if one cannot be.
    fn loadShims(self: *ModuleGraph, id: ModuleId) Error!bool {
        const m = self.get(id);
        if (m.ir == .nil) return true;
        var at: parser.Span = undefined;
        for (ir.Module.decls(m.ir)) |decl| {
            if (!decl.isKind(.zig_extern)) continue;
            const leaf = ir.ZigExtern.file(decl);
            at = m.parser.span(leaf);
            const quoted = rig.leafText(m.source, leaf.src);
            const file = quoted[1 .. quoted.len - 1];
            if (!plainZigFile(file)) {
                try self.errorAt(id, at, "`extern zig` names a Zig file of the standard library, `name.zig`", .{});
                return false;
            }
            if (!try self.addShim(id, at, file)) return false;
        }
        var next: usize = 0;
        while (next < self.get(id).shims.items.len) : (next += 1) {
            var rest = self.get(id).shims.items[next].source;
            const import = "@import(\"";
            while (std.mem.find(u8, rest, import)) |k| {
                rest = rest[k + import.len ..];
                const file = rest[0 .. std.mem.findScalar(u8, rest, '"') orelse break];
                if (!plainZigFile(file)) continue;
                for (self.get(id).shims.items) |shim| {
                    if (std.mem.eql(u8, shim.name, file)) break;
                } else if (!try self.addShim(id, at, file)) return false;
            }
        }
        return true;
    }

    /// Read `file` of the standard library as a shim of module `id`;
    /// false, with a diagnostic at `at`, if it cannot be.
    fn addShim(self: *ModuleGraph, id: ModuleId, at: parser.Span, file: []const u8) Error!bool {
        const found = self.readStd(file) catch |err| {
            try self.stdError(id, at, file, err);
            return false;
        } orelse {
            try self.errorAt(id, at, "the standard library has no Zig file `{s}`", .{file});
            return false;
        };
        try self.get(id).shims.append(self.allocator, .{ .name = file, .source = found.source });
        return true;
    }

    /// `name.zig`, with a name of letters, digits, and `_`.
    fn plainZigFile(file: []const u8) bool {
        const base = file[0..file.len -| 4];
        return std.mem.endsWith(u8, file, ".zig") and base.len > 0 and for (base) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') break false;
        } else true;
    }

    /// A file of the standard library: from `$RIG_STD` when it is set,
    /// else embedded in the compiler (null when there is no such file).
    /// `key` identifies the file in the graph, apart from every file of
    /// the program, even when `$RIG_STD` names the program's directory:
    /// a module is the standard library's or the program's, never both.
    /// `display` names it in diagnostics.
    fn readStd(self: *ModuleGraph, file: []const u8) !?struct { key: []const u8, display: []const u8, source: []const u8 } {
        const a = self.arena.allocator();
        const key = try a.print("<std>/{s}", .{file});
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
    fn add(self: *ModuleGraph, canonical: []const u8, display: []const u8, name: []const u8, source: []const u8, parts: []const diag.Part) Error!ModuleId {
        const a = self.arena.allocator();
        const id: ModuleId = @intCast(self.modules.items.len + 1);
        const p = blk: {
            // Everything that can fail comes first; the graph owns the
            // module once it is registered.
            const out_basename = if (id == 1) root_zig else try a.print("{s}.zig", .{name});
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
            const ends = try a.alloc(u32, parts.len -| 1);
            if (parts.len > 1) for (ends, parts[1..]) |*e, part| {
                e.* = part.start;
            };
            const p = try self.allocator.create(parser.Parser);
            p.* = parser.Parser.initFiles(self.allocator, source, ends);

            self.modules.appendAssumeCapacity(.{
                .id = id,
                .path = canonical,
                .display = display,
                .name = name,
                .out_basename = out_basename,
                .source = source,
                .parts = parts,
                .parser = p,
                .sema = ctx,
            });
            self.by_path.putAssumeCapacity(canonical, id);
            self.by_name.putAssumeCapacity(name, id);
            semas.putAssumeCapacity(id, ctx);
            break :blk p;
        };

        const t0 = timing.start(self.timing);
        defer timing.stop(self.timing, .lex_parse, t0);
        self.get(id).ir = p.parseProgram() catch |err| switch (err) {
            error.ParseError => {
                const d = p.diagnostic();
                try self.errorAt(id, .{ .start = d.pos, .end = d.end }, "{s}", .{d.message});
                for (p.moreDiagnostics()) |more| try self.errorAt(id, .{ .start = more.pos, .end = more.end }, "{s}", .{more.message});
                if (p.unclosedBracket()) |note| try self.get(id).sema.diagnostics.append(self.allocator, note);
                self.get(id).state = .failed;
                return id;
            },
            error.InputTooLarge => unreachable, // sources are at most `max_source_bytes`
            // `Lexer.next` returns each token it scans before it scans another.
            error.TokenEndUnknown => unreachable,
            else => |e| return e,
        };
        return id;
    }

    /// `text`, when a file read could hold it (`read`).
    fn sized(text: []const u8) error{StreamTooLong}![]const u8 {
        return if (text.len > max_source_bytes) error.StreamTooLong else text;
    }

    fn read(self: *ModuleGraph, path: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.arena.allocator(), .limited(max_source_bytes + 1));
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
        var entries: std.ArrayList(sema.ImportEntry) = .empty;
        defer entries.deinit(self.allocator);
        for (m.imports.items) |imp| {
            try entries.append(self.allocator, .{ .local_name = imp.local_name, .sema = self.get(imp.target).sema, .module_id = imp.target, .file = imp.file });
        }

        const opts: sema.CheckOptions = .{
            .parser = m.parser,
            .imports = entries.items,
            .modules = self.semas.?,
            .name = m.name,
            .module_id = id,
            .is_root = id == 1,
            .zig_file = m.out_basename,
            .is_std = m.is_std,
            .timing = self.timing,
            .parts = m.parts,
        };
        m.sema.deinit();
        m.sema.* = try sema.check(self.allocator, m.source, m.ir, opts);
        // A `for` over an iterator is the `while` it means: typecheck found
        // them, and no pass sees one once the tree is rewritten and the
        // module checked again (docs/INTERNALS.md, "Loops over an iterator").
        if (m.sema.iter_loops.items.len > 0) {
            try m.parser.desugarIterLoops(m.ir, m.sema.iter_loops.items);
            m.sema.deinit();
            m.sema.* = try sema.check(self.allocator, m.source, m.ir, opts);
            std.debug.assert(m.sema.iter_loops.items.len == 0);
        }

        // Ownership reads the types sema settled, so a module whose types
        // are wrong is not checked for ownership: its errors would follow
        // from the type errors, or be about code that means nothing yet.
        if (hasTypeErrors(m.sema.diagnostics.items)) {
            m.state = .failed;
            return;
        }
        const t0 = timing.start(self.timing);
        var own = try ownership.Checker.initWithSema(self.allocator, m.source, m.sema);
        defer own.deinit();
        try own.check(m.ir);
        timing.stop(self.timing, .ownership, t0);
        const first: u32 = @intCast(m.sema.diagnostics.items.len);
        for (own.diagnostics.items) |d| try self.addDiagnostic(id, d);
        m.own_ran = true;
        m.own_diags = .{ first, @intCast(m.sema.diagnostics.items.len) };
        // What the generic bodies copy, for the modules that import them.
        try m.sema.plain_reqs.appendSlice(self.allocator, own.ownPlainReqs());

        m.state = if (m.sema.hasErrors()) .failed else .checked;
        // Which tests are known to pass rests on the ownership checker's
        // acceptance (docs/INTERNALS.md, "Proven checks").
        const t1 = timing.start(self.timing);
        if (m.state == .checked) try proofs.check(m.sema, m.ir);
        timing.stop(self.timing, .proofs, t1);
    }

    fn errorAt(self: *ModuleGraph, id: ModuleId, at: parser.Span, comptime fmt: []const u8, args: anytype) Error!void {
        const m = self.get(id);
        const message = try m.sema.arena.allocator().print(fmt, args);
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
        for (self.modules.items, files) |m, *f| f.* = .{ .source = m.source, .path = m.display, .parts = m.parts };
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
