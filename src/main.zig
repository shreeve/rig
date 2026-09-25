//! Rig compiler CLI. `usage` below is the reference; docs/INTERNALS.md
//! describes the pipeline behind each command.
//!
//! `run`, `build`, `test`, and `emit` never emit a program the checkers
//! reject. They write the emitted package (one `.zig` file per module
//! plus the runtime in `rig/`) to the output directory, then hand it to
//! the Zig toolchain.

const std = @import("std");
const build_options = @import("build_options");
const parser = @import("parser.zig");
const ir = parser.ir;
const rig = @import("rig.zig");
const diag = @import("diag.zig");
const emit = @import("emit.zig");
const modules = @import("modules.zig");

const usage =
    \\Rig: a systems language with visible ownership, compiled to Zig.
    \\
    \\Usage: rig <command> [options] <file.rig>
    \\
    \\Commands:
    \\  check     Check the program and its imports
    \\  run       Check, build, and run the program
    \\  build     Check and build a native executable
    \\  test      Check, build, and run the program's `test` blocks
    \\  emit      Check, then print the root module's Zig to stdout
    \\
    \\Options:
    \\  --facts                Print the root module's syntax facts after
    \\                         checking it (check): every IR node with its
    \\                         kind, span, and role-named children
    \\  --release[=safe|fast]  Optimize (run, build, test): `--release` and
    \\                         `--release=safe` are ReleaseSafe, which keeps
    \\                         overflow and bounds checks; `--release=fast`
    \\                         is ReleaseFast. Default: Debug, leak-checked.
    \\  -o <path>              Executable to write (build; default ./<name>)
    \\  -h, --help             Show this help
    \\  --version              Show the version
    \\
    \\Debugging the compiler:
    \\  tokens     Dump the token stream
    \\  parse      Print the parse tree
    \\  normalize  Print the semantic IR
    \\
    \\Environment:
    \\  RIG_OUT_DIR      Directory for the emitted package (default: a
    \\                   per-project directory under $XDG_CACHE_HOME/rig,
    \\                   or ~/.cache/rig)
    \\  RIG_LEAK_TRACE   Set to 1 when building to report each leaked
    \\                   allocation with its stack trace (slower)
    \\  ZIG              The Zig 0.16 executable (default: zig on PATH)
    \\
;

const Command = enum { tokens, parse, normalize, check, run, build, @"test", emit };

/// Zig's optimize mode for the program being built.
const Mode = enum {
    debug,
    safe,
    fast,

    fn zigFlag(mode: Mode) []const u8 {
        return switch (mode) {
            .debug => "-ODebug",
            .safe => "-OReleaseSafe",
            .fast => "-OReleaseFast",
        };
    }
};

const Options = struct {
    command: Command,
    path: []const u8,
    mode: Mode = .debug,
    out_path: ?[]const u8 = null,
    facts: bool = false,
};

const Env = struct {
    map: *const std.process.Environ.Map,

    fn get(env: Env, name: []const u8) ?[]const u8 {
        const value = env.map.get(name) orelse return null;
        return if (value.len > 0) value else null;
    }

    fn zig(env: Env) []const u8 {
        return env.get("ZIG") orelse "zig";
    }

    fn leakTrace(env: Env) bool {
        const value = env.get("RIG_LEAK_TRACE") orelse return false;
        return !std.mem.eql(u8, value, "0");
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const env: Env = .{ .map = init.environ_map };
    const args = try init.minimal.args.toSlice(allocator);
    const opts = parseArgs(io, args[@min(1, args.len)..]);

    switch (opts.command) {
        .tokens, .parse, .normalize => {
            const source = std.Io.Dir.cwd().readFileAlloc(io, opts.path, allocator, .limited(modules.max_source_bytes)) catch |err|
                fatal("error: cannot read `{s}`: {s}", .{ opts.path, modules.fileError(err) });
            switch (opts.command) {
                .tokens => try dumpTokens(io, opts.path, source),
                .parse => try printTree(allocator, io, opts.path, source, .raw),
                .normalize => try printTree(allocator, io, opts.path, source, .semantic),
                else => unreachable,
            }
        },
        .check => {
            var graph = try loadProject(allocator, io, opts.path);
            defer graph.deinit();
            if (opts.facts) try printFacts(io, graph.root());
        },
        .emit => try emitCommand(allocator, io, env, opts.path),
        .run => try runCommand(allocator, io, env, opts),
        .build => try buildCommand(allocator, io, env, opts),
        .@"test" => try testCommand(allocator, io, env, opts),
    }
}

fn parseArgs(io: std.Io, args: []const []const u8) Options {
    var command: ?Command = null;
    var path: ?[]const u8 = null;
    var mode: Mode = .debug;
    var out_path: ?[]const u8 = null;
    var facts = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        // `help` and `version` are commands only in the command's place,
        // so a file may have either name.
        const first = command == null;
        if (eql(arg, "-h") or eql(arg, "--help") or (first and eql(arg, "help"))) {
            printOut(io, "{s}", .{usage});
            std.process.exit(0);
        } else if (eql(arg, "--version") or (first and eql(arg, "version"))) {
            printOut(io, "rig {s}\n", .{build_options.version});
            std.process.exit(0);
        } else if (eql(arg, "--release") or eql(arg, "--release=safe")) {
            mode = .safe;
        } else if (eql(arg, "--release=fast")) {
            mode = .fast;
        } else if (eql(arg, "--facts")) {
            facts = true;
        } else if (eql(arg, "-o")) {
            i += 1;
            if (i == args.len) usageError("-o needs a path", .{});
            out_path = args[i];
        } else if (arg.len > 1 and arg[0] == '-') {
            usageError("unknown option `{s}`", .{arg});
        } else if (command == null) {
            command = std.meta.stringToEnum(Command, arg) orelse usageError("unknown command `{s}`", .{arg});
        } else if (path == null) {
            path = arg;
        } else {
            usageError("unexpected argument `{s}`", .{arg});
        }
    }
    const cmd = command orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    };
    if (mode != .debug and cmd != .run and cmd != .build and cmd != .@"test")
        usageError("`--release` applies to run, build, and test", .{});
    if (out_path != null and cmd != .build) usageError("`-o` applies to build", .{});
    if (facts and cmd != .check) usageError("`--facts` applies to check", .{});
    const file = path orelse usageError("`rig {s}` needs a .rig file", .{@tagName(cmd)});
    // `rig build` writes ./<name>: a file without `.rig` would be its own
    // output.
    const base = std.fs.path.basename(file);
    if (!std.mem.endsWith(u8, base, ".rig") or base.len == ".rig".len) usageError("`{s}` is not a .rig file", .{file});
    return .{
        .command = cmd,
        .path = file,
        .mode = mode,
        .out_path = out_path,
        .facts = facts,
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn usageError(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\nRun `rig --help` for usage.\n", args);
    std.process.exit(2);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

/// Print to stdout, unbuffered past this call.
fn printOut(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    writer.interface.print(fmt, args) catch {};
    writer.interface.flush() catch {};
}

/// `rig tokens`: the token stream on stdout; a lexer error ends it with a
/// diagnostic on stderr and exit status 1.
fn dumpTokens(io: std.Io, path: []const u8, source: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &writer.interface;
    var lexer = rig.Lexer.init(source);
    var lines: diag.Lines = .{ .source = source };
    var i: u32 = 0;
    while (true) : (i += 1) {
        const tok = lexer.next();
        const lc = lines.at(tok.pos);
        try w.print("{d:4} {d}:{d} {s:15} \"{s}\"\n", .{ i, lc.line, lc.col, @tagName(tok.cat), lexer.text(tok) });
        if (tok.cat == .eof) break;
        if (tok.cat == .err) {
            try w.flush();
            var err_buffer: [4096]u8 = undefined;
            var err_writer = std.Io.File.stderr().writerStreaming(io, &err_buffer);
            try diag.write(&.{.{ .severity = .@"error", .pos = tok.pos, .end = tok.pos + tok.len, .message = lexer.err.message() }}, source, path, &err_writer.interface);
            try err_writer.interface.flush();
            std.process.exit(1);
        }
    }
    try w.flush();
}

/// Print the parse tree (`raw`: grammar output only) or the semantic IR.
fn printTree(allocator: std.mem.Allocator, io: std.Io, path: []const u8, source: []const u8, stage: enum { raw, semantic }) !void {
    var p = parser.Parser.init(allocator, source);
    defer p.deinit();
    const tree = switch (stage) {
        .raw => p.parseTree(),
        .semantic => p.parseProgram(),
    } catch |err| switch (err) {
        error.ParseError => {
            var buffer: [4096]u8 = undefined;
            var writer = std.Io.File.stderr().writerStreaming(io, &buffer);
            try diag.write(&.{p.diagnostic()}, source, path, &writer.interface);
            if (p.unclosedBracket()) |note| try diag.write(&.{note}, source, path, &writer.interface);
            try writer.interface.flush();
            std.process.exit(1);
        },
        else => return err,
    };

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    try tree.write(source, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

/// `rig check --facts`: the root module's IR as flat facts, one per
/// line (see `BaseParser.writeFacts` in the generated parser):
///
///   (node ID KIND START END)   every node the parser built, with its span
///   (role ID ROLE CHILD...)    each non-empty role: a node id, `leaf POS
///                              LEN`, or `tag NAME`
fn printFacts(io: std.Io, m: *const modules.Module) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    try m.parser.base.writeFacts(&writer.interface, m.ir);
    try writer.interface.flush();
}

/// Load and check the project rooted at `path`; print every diagnostic
/// and exit 1 if there are errors.
fn loadProject(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !modules.ModuleGraph {
    var graph = modules.ModuleGraph.init(allocator, io);
    errdefer graph.deinit();
    try graph.loadRoot(path);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    try graph.writeAllDiagnostics(&writer.interface);
    try writer.interface.flush();
    if (graph.hasErrors()) std.process.exit(1);
    return graph;
}

/// `rig emit`: the root module's Zig on stdout; the whole package
/// (imports and runtime) is written to the output directory.
fn emitCommand(allocator: std.mem.Allocator, io: std.Io, env: Env, path: []const u8) !void {
    var graph = try loadProject(allocator, io, path);
    defer graph.deinit();
    const pkg = try emitPackage(allocator, io, env, &graph);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    try writer.interface.writeAll(pkg.root_source);
    try writer.interface.flush();
    std.debug.print("note: the package (every module and the runtime, {s}) is in {s}\n", .{ emit.runtime_filename, pkg.dir });
}

fn runCommand(allocator: std.mem.Allocator, io: std.Io, env: Env, opts: Options) !void {
    var graph = try loadProject(allocator, io, opts.path);
    defer graph.deinit();
    requireMain(&graph);
    const pkg = try emitPackage(allocator, io, env, &graph);
    // Zig's own errors name the emitted files; any other failure is the
    // program's.
    const code = try runZig(io, &.{ env.zig(), "run", opts.mode.zigFlag(), pkg.root_zig });
    if (code != 0) std.process.exit(code);
}

fn buildCommand(allocator: std.mem.Allocator, io: std.Io, env: Env, opts: Options) !void {
    var graph = try loadProject(allocator, io, opts.path);
    defer graph.deinit();
    requireMain(&graph);
    const pkg = try emitPackage(allocator, io, env, &graph);
    const out = opts.out_path orelse try std.fmt.allocPrint(allocator, "{s}", .{graph.root().name});
    const emit_bin = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{out});
    const code = try runZig(io, &.{ env.zig(), "build-exe", opts.mode.zigFlag(), pkg.root_zig, emit_bin });
    if (code != 0) {
        std.debug.print("note: emitted Zig is in {s}\n", .{pkg.dir});
        std.process.exit(code);
    }
}

/// `rig test`: a driver module next to the emitted ones runs the
/// `__rig_tests` table of every module (see `rig.runTests`).
fn testCommand(allocator: std.mem.Allocator, io: std.Io, env: Env, opts: Options) !void {
    var graph = try loadProject(allocator, io, opts.path);
    defer graph.deinit();
    const pkg = try emitPackage(allocator, io, env, &graph);

    var driver: std.Io.Writer.Allocating = .init(allocator);
    const w = &driver.writer;
    try w.print(
        \\const rig = @import("{s}");
        \\
        \\pub const panic = rig.panic;
        \\
    , .{emit.runtime_filename});
    if (env.leakTrace()) try w.writeAll("pub const __rig_leak_trace = true;\n");
    try w.writeAll(
        \\
        \\fn testsOf(comptime module: type) []const rig.Test {
        \\    return if (@hasDecl(module, "__rig_tests")) &module.__rig_tests else &.{};
        \\}
        \\
        \\pub fn main() void {
        \\    rig.runTests(&.{
        \\
    );
    for (graph.modules.items, 0..) |m, i| {
        try w.print("        .{{ .module = \"{s}\", .tests = testsOf(@import(\"{s}\")) }},\n", .{ if (i == 0) "" else m.name, m.out_basename });
    }
    try w.writeAll("    });\n}\n");
    const driver_path = try std.fs.path.join(allocator, &.{ pkg.dir, test_driver });
    try writeFile(io, driver_path, driver.written());

    const code = try runZig(io, &.{ env.zig(), "run", opts.mode.zigFlag(), driver_path });
    if (code != 0) std.process.exit(code);
}

const test_driver = "__rig_test.zig";

fn requireMain(graph: *modules.ModuleGraph) void {
    if (!declaresMain(graph.root())) fatal("{s}:1:1: error: no `sub main()` to run", .{graph.root().display});
}

/// Run the Zig toolchain with inherited stdio; return its exit code
/// (128 + the signal number if a signal ended it).
fn runZig(io: std.Io, argv: []const []const u8) !u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.FileNotFound => fatal("error: cannot run `{s}`: install Zig 0.16 and put it on PATH, or set ZIG", .{argv[0]}),
        else => return err,
    };
    return switch (try child.wait(io)) {
        .exited => |code| code,
        .signal => |sig| 128 +| @as(u8, @truncate(@intFromEnum(sig))),
        else => 1,
    };
}

fn declaresMain(m: *const modules.Module) bool {
    if (m.ir == .nil) return false;
    for (ir.Module.decls(m.ir)) |top| {
        const decl = if (top.isKind(.@"pub")) ir.Pub.decl(top) else top;
        if (!decl.isKind(.sub) and !decl.isKind(.fun)) continue;
        if (std.mem.eql(u8, ir.get(decl, .name).getText(m.source), "main")) return true;
    }
    return false;
}

const Package = struct {
    /// The output directory.
    dir: []const u8,
    /// The root module's `.zig` file, and its contents.
    root_zig: []const u8,
    root_source: []const u8,
};

/// Write the runtime and every module to the output directory. With
/// `RIG_LEAK_TRACE` set, the root module asks the runtime for
/// stack-trace leak reports.
fn emitPackage(allocator: std.mem.Allocator, io: std.Io, env: Env, graph: *modules.ModuleGraph) !Package {
    const dir = try outputDir(allocator, env, graph.root());

    try writeFile(io, try std.fs.path.join(allocator, &.{ dir, emit.runtime_filename }), emit.runtime_source);

    var root_source: []const u8 = "";
    for (graph.modules.items, 0..) |*m, i| {
        var file_buffer: std.Io.Writer.Allocating = .init(allocator);
        var em = emit.Emitter.init(allocator, m.source, &file_buffer.writer, m.sema);
        defer em.deinit();
        try em.emit(m.ir);
        if (i == 0 and env.leakTrace()) try file_buffer.writer.writeAll("\npub const __rig_leak_trace = true;\n");
        try writeFile(io, try std.fs.path.join(allocator, &.{ dir, m.out_basename }), file_buffer.written());
        if (i == 0) root_source = file_buffer.written();
    }
    return .{
        .dir = dir,
        .root_zig = try std.fs.path.join(allocator, &.{ dir, graph.root().out_basename }),
        .root_source = root_source,
    };
}

/// Replace `path` with `contents` atomically, so a concurrent build of the
/// same program never reads a partly written file.
fn writeFile(io: std.Io, path: []const u8, contents: []const u8) !void {
    var file = std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true }) catch |err|
        fatal("error: cannot write `{s}`: {s}", .{ path, @errorName(err) });
    defer file.deinit(io);
    file.file.writeStreamingAll(io, contents) catch |err| fatal("error: cannot write `{s}`: {s}", .{ path, @errorName(err) });
    file.replace(io) catch |err| fatal("error: cannot write `{s}`: {s}", .{ path, @errorName(err) });
}

/// `$RIG_OUT_DIR` when set (used as is). Otherwise a directory private to
/// this user and project under the cache home.
fn outputDir(allocator: std.mem.Allocator, env: Env, root: *const modules.Module) ![]const u8 {
    if (env.get("RIG_OUT_DIR")) |dir| return dir;

    const base = if (env.get("XDG_CACHE_HOME")) |x|
        try std.fs.path.join(allocator, &.{ x, "rig" })
    else if (env.get("HOME")) |home|
        try std.fs.path.join(allocator, &.{ home, ".cache", "rig" })
    else
        fatal("error: set RIG_OUT_DIR, XDG_CACHE_HOME, or HOME for emitted Zig", .{});

    const project = try std.fmt.allocPrint(allocator, "{s}-{x:0>16}", .{ root.name, std.hash.Wyhash.hash(0, root.path) });
    return std.fs.path.join(allocator, &.{ base, project });
}

// The unit tests of every compiler file, and of the runtime.
test {
    _ = rig;
    _ = diag;
    _ = modules;
    _ = emit;
    _ = @import("sema.zig");
    _ = @import("ownership.zig");
    _ = @import("runtime.zig");
}
