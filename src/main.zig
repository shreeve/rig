//! Rig Compiler — CLI Driver
//!
//! Subcommands:
//!   rig parse     <file.rig>  — print raw S-expression tree (BaseParser only, no rewrites)
//!   rig tokens    <file.rig>  — dump token stream (debug)
//!   rig normalize <file.rig>  — print fully-normalized semantic IR
//!   rig check     <file.rig>  — run ownership / borrow / effects checks; exit 1 on errors
//!   rig build     <file.rig>  — check + emit Zig source to stdout
//!   rig run       <file.rig>  — check + emit Zig + spawn `zig run`
//!
//! `build` and `run` always run the full checker pipeline first; if any
//! diagnostics are produced the process exits 1 BEFORE emit. Bypassing
//! the checker is intentionally not exposed (see SPEC §"visible effects").

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const types = @import("types.zig");
const effects = @import("effects.zig");
const ownership = @import("ownership.zig");
const emit = @import("emit.zig");
const modules = @import("modules.zig");
const runtime_zig = @import("runtime_zig.zig");

const Mode = enum {
    parse,
    tokens,
    normalize,
    check,
    build,
    run,
};

const usage =
    \\Rig — a systems language with explicit ownership, transpiling to Zig.
    \\
    \\Usage:
    \\  rig <subcommand> <file.rig>
    \\
    \\Subcommands:
    \\  parse      Print raw S-expression tree (BaseParser only)
    \\  tokens     Dump token stream (debug)
    \\  normalize  Print fully-normalized semantic IR
    \\  check      Run ownership / borrow / effects checks
    \\  build      check + emit Zig source to stdout
    \\  run        check + emit Zig + zig run
    \\
    \\Options:
    \\  -h, --help  Show this message
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    }

    const sub = args[1];
    if (std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "help")) {
        std.debug.print("{s}", .{usage});
        return;
    }

    const mode: Mode = blk: {
        if (std.mem.eql(u8, sub, "parse")) break :blk .parse;
        if (std.mem.eql(u8, sub, "tokens")) break :blk .tokens;
        if (std.mem.eql(u8, sub, "normalize")) break :blk .normalize;
        if (std.mem.eql(u8, sub, "check")) break :blk .check;
        if (std.mem.eql(u8, sub, "build")) break :blk .build;
        if (std.mem.eql(u8, sub, "run")) break :blk .run;
        std.debug.print("Unknown subcommand: {s}\n\n{s}", .{ sub, usage });
        std.process.exit(1);
    };

    if (args.len < 3) {
        std.debug.print("Subcommand `{s}` requires a file path.\n", .{sub});
        std.process.exit(1);
    }

    const file_path = args[2];

    const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(16 * 1024 * 1024)) catch |err| {
        std.debug.print("error reading {s}: {}\n", .{ file_path, err });
        std.process.exit(1);
    };

    switch (mode) {
        .parse => try parseAndPrint(allocator, io, source),
        .tokens => dumpTokens(source),
        .normalize => try normalizeAndPrint(allocator, io, source),
        .check => try checkAndReport(allocator, io, source, file_path),
        .build => try buildAndEmit(allocator, io, file_path),
        .run => try buildAndRun(allocator, io, file_path),
    }
}

fn parseAndPrint(allocator: std.mem.Allocator, io: std.Io, source: []const u8) !void {
    // Debug path: print the RAW parse tree (before rig.Parser rewriting).
    // Uses BaseParser explicitly to skip the wrapper.
    var p = parser.BaseParser.init(allocator, source);
    defer p.deinit();

    const result = p.parseProgram() catch {
        p.printError();
        std.process.exit(1);
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const w: *std.Io.Writer = &stdout_writer.interface;
    try result.write(source, w);
    try w.writeAll("\n");
    try w.flush();
}

fn normalizeAndPrint(allocator: std.mem.Allocator, io: std.Io, source: []const u8) !void {
    // `parser.Parser` auto-wires to `rig.Parser`, so `parseProgram()`
    // returns the fully-rewritten semantic IR in one call.
    var p = parser.Parser.init(allocator, source);
    defer p.deinit();

    const out = p.parseProgram() catch {
        p.printError();
        std.process.exit(1);
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const w: *std.Io.Writer = &stdout_writer.interface;
    try out.write(source, w);
    try w.writeAll("\n");
    try w.flush();
}

fn checkAndReport(allocator: std.mem.Allocator, io: std.Io, source: []const u8, file_path: []const u8) !void {
    var p = parser.Parser.init(allocator, source);
    defer p.deinit();

    const ir = p.parseProgram() catch {
        p.printError();
        std.process.exit(1);
    };

    // Sema → Effects → Ownership. Sema produces the symbol/type
    // context; effects.Checker now consumes sema directly (no
    // duplicate signature scan). Ownership still operates
    // independently — M5(5/n) wires it through.
    var sema = try types.check(allocator, source, ir);
    defer sema.deinit();

    var eff = try effects.Checker.initWithSema(allocator, source, &sema);
    defer eff.deinit();
    try eff.check(ir);

    var checker = try ownership.Checker.initWithSema(allocator, source, &sema);
    defer checker.deinit();
    try checker.check(ir);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const w: *std.Io.Writer = &stdout_writer.interface;
    try sema.writeDiagnostics(file_path, w);
    try eff.writeDiagnostics(file_path, w);
    try checker.writeDiagnostics(file_path, w);
    try w.flush();

    if (sema.hasErrors() or eff.hasErrors() or checker.hasErrors()) std.process.exit(1);
}

/// Bundle returned from `parseAndCheckOrExit`. The caller owns both
/// the IR (lives in the parser's arena, which lives as long as the
/// caller's allocator) and the SemContext (caller MUST `sema.deinit()`).
/// Both are needed by emit so we return them as a unit instead of
/// forcing each call site to re-run sema.
const CheckedProgram = struct {
    ir: parser.Sexp,
    sema: types.SemContext,
};

/// Parse + run the full checker pipeline (sema → effects → ownership)
/// and abort the process with exit 1 if any errors are emitted. Used
/// by `build` and `run` so they never lower a program the checker
/// rejects.
///
/// Diagnostics go to stderr so callers can pipe emit to stdout.
fn parseAndCheckOrExit(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    file_path: []const u8,
) !CheckedProgram {
    var p = parser.Parser.init(allocator, source);
    // NOTE: we intentionally do NOT deinit `p` here — the returned IR
    // is allocated in its arena and must outlive this function. The
    // caller's arena (in main) owns the parser's lifetime via the same
    // top-level allocator.
    const ir = p.parseProgram() catch {
        p.printError();
        std.process.exit(1);
    };

    var sema = try types.check(allocator, source, ir);
    errdefer sema.deinit();

    var eff = try effects.Checker.initWithSema(allocator, source, &sema);
    defer eff.deinit();
    try eff.check(ir);

    var checker = try ownership.Checker.initWithSema(allocator, source, &sema);
    defer checker.deinit();
    try checker.check(ir);

    if (sema.hasErrors() or eff.hasErrors() or checker.hasErrors()) {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
        const ew: *std.Io.Writer = &stderr_writer.interface;
        try sema.writeDiagnostics(file_path, ew);
        try eff.writeDiagnostics(file_path, ew);
        try checker.writeDiagnostics(file_path, ew);
        try ew.flush();
        std.process.exit(1);
    }

    return .{ .ir = ir, .sema = sema };
}

/// Load + check the project rooted at `file_path` via the module
/// graph driver. Aborts with exit 1 if any error diagnostics are
/// produced (parse, sema, effects, ownership, cycles, missing files).
/// Returns the loaded graph; caller must `deinit`.
fn loadProjectOrExit(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
) !modules.ModuleGraph {
    // M15 v1: paths are kept as-given. The root file's path is used
    // verbatim; imports are resolved as `dirname(importer) + name.rig`
    // via `std.fs.path.resolve`. Same-dir-only imports + same-string
    // dedup is enough for the simple case. (Zig 0.16's stdlib doesn't
    // expose a portable `realpath` / `getcwd`; M15b can canonicalize
    // once we settle on an OS-portable approach.)
    var graph = modules.ModuleGraph.init(allocator, io);
    errdefer graph.deinit();

    _ = graph.loadRoot(file_path) catch |err| {
        std.debug.print("error: failed to load `{s}`: {}\n", .{ file_path, err });
        std.process.exit(1);
    };

    if (graph.hasErrors()) {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
        const ew: *std.Io.Writer = &stderr_writer.interface;
        try graph.writeAllDiagnostics(ew);
        try ew.flush();
        std.process.exit(1);
    }

    return graph;
}

/// Emit all modules in the graph to a temp directory. Returns the
/// path to the ROOT module's emitted .zig (suitable for `zig run`).
fn emitProjectToTmp(
    allocator: std.mem.Allocator,
    io: std.Io,
    graph: *modules.ModuleGraph,
) ![]const u8 {
    // Pick a temp dir based on the root module's name.
    const root = &graph.modules.items[1]; // module 1 is always root
    var tmpdir_buf: [256]u8 = undefined;
    const tmpdir = std.fmt.bufPrint(&tmpdir_buf, "/tmp/rig_{s}", .{root.name}) catch "/tmp/rig_out";

    // Make the dir (best-effort; exists is fine).
    std.Io.Dir.cwd().createDir(io, tmpdir, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => {
            std.debug.print("error: cannot create {s}: {}\n", .{ tmpdir, e });
            std.process.exit(1);
        },
    };

    // M20d: write the Rig runtime as a sibling file. Every emitted
    // module's prelude includes `const rig = @import("_rig_runtime.zig");`
    // so they all resolve relative to this directory. Per GPT-5.5's
    // M20d design pass: keep it as a plain sibling file, no package
    // machinery. Unconditional write — top-level unused namespace
    // imports are fine in Zig.
    {
        const runtime_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmpdir, runtime_zig.filename });
        const rf = std.Io.Dir.cwd().createFile(io, runtime_path, .{}) catch |err| {
            std.debug.print("error creating {s}: {}\n", .{ runtime_path, err });
            std.process.exit(1);
        };
        defer rf.close(io);

        var rt_buffer: [4096]u8 = undefined;
        var rt_writer = rf.writer(io, &rt_buffer);
        const rw: *std.Io.Writer = &rt_writer.interface;
        try rw.writeAll(runtime_zig.source);
        try rw.flush();
    }

    var root_path: []const u8 = "";

    for (graph.modules.items[1..]) |*m| {
        // Defensive: only emit modules that actually loaded. Callers
        // gate on `graph.hasErrors()` before reaching here, but skip
        // failed modules so a regression in that gate can't crash emit.
        if (m.state != .loaded) continue;
        const sema = m.sema orelse continue;

        const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmpdir, m.out_basename });

        const f = std.Io.Dir.cwd().createFile(io, out_path, .{}) catch |err| {
            std.debug.print("error creating {s}: {}\n", .{ out_path, err });
            std.process.exit(1);
        };
        defer f.close(io);

        var file_buffer: [4096]u8 = undefined;
        var file_writer = f.writer(io, &file_buffer);
        const w: *std.Io.Writer = &file_writer.interface;

        var em = emit.Emitter.initWithSema(allocator, m.source, w, sema);
        defer em.deinit();
        try em.emit(m.ir);
        try w.flush();

        if (m.id == 1) root_path = out_path;
    }

    return root_path;
}

fn buildAndEmit(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) !void {
    var graph = try loadProjectOrExit(allocator, io, file_path);
    defer graph.deinit();

    // Single-file project: emit to stdout (preserves M0–M14 behavior).
    // Multi-file project: emit all to a temp dir AND echo the root's
    // Zig to stdout, with a note pointing at the dir.
    const root = &graph.modules.items[1];
    const has_imports = root.imports.items.len > 0;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const w: *std.Io.Writer = &stdout_writer.interface;

    if (!has_imports) {
        const sema = root.sema orelse {
            std.debug.print("internal error: root module missing sema\n", .{});
            std.process.exit(1);
        };
        var em = emit.Emitter.initWithSema(allocator, root.source, w, sema);
        defer em.deinit();
        try em.emit(root.ir);
    } else {
        // Multi-module: emit all to a tmp dir; print the root path so
        // the user can find it. (Single-file behavior — emitting to
        // stdout — doesn't generalize to a multi-file project.)
        const root_path = try emitProjectToTmp(allocator, io, &graph);
        std.debug.print("project emitted to {s}\nroot: {s}\n", .{
            std.fs.path.dirname(root_path) orelse "/tmp",
            root_path,
        });
    }
    try w.flush();
}

fn buildAndRun(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) !void {
    var graph = try loadProjectOrExit(allocator, io, file_path);
    defer graph.deinit();

    const root_path = try emitProjectToTmp(allocator, io, &graph);

    const argv = [_][]const u8{ "zig", "run", root_path };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("note: project emitted to {s}\n", .{std.fs.path.dirname(root_path) orelse "/tmp"});
            std.process.exit(code);
        },
        else => std.process.exit(1),
    }
}

fn makeTmpPath(buf: []u8, rig_path: []const u8) []const u8 {
    var start: usize = 0;
    for (rig_path, 0..) |c, i| {
        if (c == '/' or c == '\\') start = i + 1;
    }
    var base = rig_path[start..];
    if (base.len > 4 and std.mem.eql(u8, base[base.len - 4 ..], ".rig")) {
        base = base[0 .. base.len - 4];
    }
    const prefix = "/tmp/rig_";
    const suffix = ".zig";
    if (prefix.len + base.len + suffix.len > buf.len) return "/tmp/_rig_out.zig";
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..base.len], base);
    @memcpy(buf[prefix.len + base.len ..][0..suffix.len], suffix);
    return buf[0 .. prefix.len + base.len + suffix.len];
}

fn dumpTokens(source: []const u8) void {
    var lexer = rig.Lexer.init(source);
    var i: u32 = 0;
    while (true) {
        const tok = lexer.next();
        const text = if (tok.len > 0) source[tok.pos..][0..tok.len] else "";
        std.debug.print("{d:3}: {s:15} pre={d} pos={d} len={d} \"{s}\"\n", .{
            i, @tagName(tok.cat), tok.pre, tok.pos, tok.len, text,
        });
        if (tok.cat == .eof) break;
        i += 1;
    }
}
