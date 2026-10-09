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
const emit_facts = @import("facts.zig");
const modules = @import("modules.zig");
const sema = @import("sema.zig");

const usage =
    \\Rig: a systems language with visible ownership, compiled to Zig.
    \\
    \\Usage: rig <command> [options] <file.rig>
    \\       rig run [options] <file.rig> -- <program arguments>
    \\       rig clean
    \\
    \\Commands:
    \\  check     Check the program and its imports
    \\  run       Check, build, and run the program
    \\  build     Check and build a native executable
    \\  test      Check, build, and run the program's `test` blocks
    \\  emit      Check, then print the root module's Zig to stdout
    \\  clean     Remove the programs rig built in its cache (see RIG_OUT_DIR)
    \\
    \\Options:
    \\  --facts                Print the root module's syntax facts after
    \\                         checking it (check): every IR node with its
    \\                         kind, span, and role-named children
    \\  --facts=sema           Print the facts sema recorded for the root
    \\                         module's expressions instead (check)
    \\  --facts=storage        Print the hidden storage emit makes for the
    \\                         root module instead (check)
    \\  --release[=safe|fast]  Optimize (run, build, test): `--release` and
    \\                         `--release=safe` are Zig's safe mode, which
    \\                         keeps overflow and bounds checks;
    \\                         `--release=fast` is its fast mode. Default:
    \\                         debug, leak-checked.
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
    \\  RIG_OUT_DIR      Directory for the emitted package and its Zig
    \\                   build cache (default: a per-project directory
    \\                   under $XDG_CACHE_HOME/rig, or ~/.cache/rig,
    \\                   where run, build, and test, at most once a
    \\                   day, remove the directories unused for 5 days,
    \\                   and only in a home holding rig's CACHEDIR.TAG;
    \\                   a relative XDG_CACHE_HOME or HOME is ignored)
    \\  RIG_BUILD_STORE  A store shared by every program and checkout:
    \\                   run, build, and test write the package to a
    \\                   directory in it named by a hash of everything
    \\                   the build reads, and build there, in place of
    \\                   RIG_OUT_DIR
    \\  RIG_RUN_STARTED  A file run and test delete at once, and create
    \\                   only once the program has started, which proves
    \\                   it ran. Any failure before the program starts
    \\                   prints `rig: the program did not run` and exits
    \\                   125
    \\  RIG_LEAK_TRACE   Set to 1 when building to report each leaked
    \\                   allocation with its stack trace (slower)
    \\  RIG_SANITIZE     Set to 1 when building a Debug program to make
    \\                   any use of freed memory crash where it happens
    \\                   (much slower; `./test/run` sets it)
    \\  RIG_STD          For developing the standard library: a directory
    \\                   to read it from, in place of the copy built into
    \\                   rig
    \\  ZIG              The Zig 0.17 executable (default: zig on PATH)
    \\
;

const Command = enum { tokens, parse, normalize, check, run, build, @"test", emit, clean };

/// Zig's optimize mode for the program being built.
const Mode = enum {
    debug,
    safe,
    fast,

    fn zigFlag(mode: Mode) []const u8 {
        return switch (mode) {
            .debug => "-Odebug",
            .safe => "-Osafe",
            .fast => "-Ofast",
        };
    }
};

/// What `check --facts` prints: the IR's syntax facts, sema's, or the
/// hidden storage emit makes.
const Facts = enum { none, syntax, sema, storage };

const Options = struct {
    command: Command,
    path: []const u8,
    mode: Mode = .debug,
    out_path: ?[]const u8 = null,
    facts: Facts = .none,
    /// `rig run file.rig -- args...`: the program's own arguments.
    program_args: []const []const u8 = &.{},
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
        return env.flag("RIG_LEAK_TRACE");
    }

    fn sanitize(env: Env) bool {
        return env.flag("RIG_SANITIZE");
    }

    /// Set, and not to `0`.
    fn flag(env: Env, name: []const u8) bool {
        const value = env.get(name) orelse return false;
        return !std.mem.eql(u8, value, "0");
    }

    /// The declarations that ask the runtime for leak traces or the
    /// sanitizer, written into the root module (`runtime.zig`); and, in a
    /// package `rig run` or `rig test` builds (`hook`), the variable
    /// naming the file the program creates as it starts (`buildCommand`).
    fn writeRootFlags(env: Env, w: *std.Io.Writer, hook: bool) !void {
        if (env.leakTrace()) try w.writeAll("pub const __rig_leak_trace = true;\n");
        if (env.sanitize()) try w.writeAll("pub const __rig_sanitize = true;\n");
        if (hook) try w.writeAll("pub const __rig_run_started = \"" ++ program_started_var ++ "\";\n");
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const env: Env = .{ .map = init.environ_map };
    const args = try init.minimal.args.toSlice(allocator);
    const opts = parseArgs(io, args[@min(1, args.len)..]);

    switch (opts.command) {
        .clean => clean(allocator, io, env),
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
            var graph = try loadProject(allocator, io, env, opts.path);
            defer graph.deinit();
            switch (opts.facts) {
                .none => {},
                .syntax => try printFacts(io, graph.root()),
                .sema, .storage => {
                    const m = graph.root();
                    var buffer: [4096]u8 = undefined;
                    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
                    if (opts.facts == .sema)
                        try sema.writeFactsDump(m.sema, allocator, m.ir, &writer.interface)
                    else
                        try sema.writeStorageDump(m.sema, allocator, m.ir, &writer.interface);
                    try writer.interface.flush();
                },
            }
        },
        .emit => try emitCommand(allocator, io, env, opts.path),
        .run, .build, .@"test" => buildCommand(allocator, io, env, opts) catch |err| {
            if (program_pending) notRun("{s}", .{@errorName(err)});
            return err;
        },
    }
}

fn parseArgs(io: std.Io, args: []const []const u8) Options {
    var command: ?Command = null;
    var path: ?[]const u8 = null;
    var mode: Mode = .debug;
    var out_path: ?[]const u8 = null;
    var facts: Facts = .none;
    var program_args: []const []const u8 = &.{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--")) {
            if (command != .run) usageError("arguments after `--` are for the program `rig run` runs", .{});
            program_args = args[i + 1 ..];
            break;
        }
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
            facts = .syntax;
        } else if (eql(arg, "--facts=sema")) {
            facts = .sema;
        } else if (eql(arg, "--facts=storage")) {
            facts = .storage;
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
    if (facts != .none and cmd != .check) usageError("`--facts` applies to check", .{});
    if (cmd == .clean) {
        if (path != null) usageError("`rig clean` takes no file", .{});
        return .{ .command = cmd, .path = "" };
    }
    const file = path orelse usageError("`rig {s}` needs a .rig file", .{@tagName(cmd)});
    // `rig build` writes ./<name>: a file without `.rig` would be its own
    // output.
    const base = std.fs.path.basename(file);
    if (!std.mem.endsWith(u8, base, ".rig") or base.len == ".rig".len) usageError("`{s}` is not a .rig file", .{file});
    // Every source file ends in `.rig`, so an executable never replaces
    // one, even where file names ignore case.
    if (out_path) |o| if (std.ascii.endsWithIgnoreCase(o, ".rig")) usageError("`-o {s}` would write the executable over a .rig file", .{o});
    return .{ .command = cmd, .path = file, .mode = mode, .out_path = out_path, .facts = facts, .program_args = program_args };
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
    if (program_pending) notRun("rig failed", .{});
    std.process.exit(1);
}

/// `rig run` and `rig test` exit with the program's own status only once
/// the program has started; any failure before that, rig's own, Zig's, or
/// in starting the program, prints `rig: the program did not run` and
/// exits with this status. So a test harness can tell a program that ran
/// from one that never did.
const not_run_status: u8 = 125;

/// The environment variable naming the file `rig run` and `rig test`
/// create once the program has started: a caller's evidence it ran.
const run_started_var = "RIG_RUN_STARTED";

/// The environment variable naming the file a program that `rig run` or
/// `rig test` builds creates as it starts: rig's own evidence, a fresh
/// path for each attempt.
const program_started_var = "RIG_PROGRAM_STARTED";

/// Set while `rig run` or `rig test` builds and starts a checked program:
/// a failure now means the program did not run.
var program_pending = false;

fn notRun(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: rig: the program did not run: " ++ fmt ++ "\n", args);
    std.process.exit(not_run_status);
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
        try w.print("{d:4} {d}:{d} {s:15} \"{s}\"\n", .{ i, lc.line, lc.col, @tagName(tok.cat), lexer.base.text(tok) });
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
            try diag.write(p.moreDiagnostics(), source, path, &writer.interface);
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
fn loadProject(allocator: std.mem.Allocator, io: std.Io, env: Env, path: []const u8) !modules.ModuleGraph {
    var graph = modules.ModuleGraph.init(allocator, io);
    errdefer graph.deinit();
    graph.std_dir = env.get("RIG_STD");
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
    var graph = try loadProject(allocator, io, env, path);
    defer graph.deinit();
    const pkg = try emitPackage(allocator, env, &graph, false);
    const dir = try outputDir(allocator, env, graph.root());
    try writePackage(allocator, io, dir, pkg.files.items);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    try writer.interface.writeAll(pkg.root_source);
    try writer.interface.flush();
    std.debug.print("note: the package (every module and the runtime, {s}) is in {s}\n", .{ emit.runtime_filename, dir });
    // Not in any file of the package, but in what `run` and `build` hand Zig.
    if (pkg.links_libc) std.debug.print("note: Zig links it with libc (-lc)\n", .{});
}

/// `rig run`, `build`, and `test`: emit the package and hand it to Zig.
/// Zig's own errors name the emitted files; any other failure of `run`
/// or `test` is the program's.
fn buildCommand(allocator: std.mem.Allocator, io: std.Io, env: Env, opts: Options) !void {
    // A caller's RIG_RUN_STARTED is cleared first, and created only once
    // the program has started, so it never outlives a failure.
    if (opts.command != .build) if (env.get(run_started_var)) |path| {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => notRun("cannot clear RIG_RUN_STARTED `{s}`: {s}", .{ path, @errorName(err) }),
        };
    };
    var graph = try loadProject(allocator, io, env, opts.path);
    defer graph.deinit();
    if (opts.command != .@"test" and !declaresMain(graph.root())) fatal("{s}:1:1: error: no `sub main()` to run", .{graph.root().display});
    program_pending = opts.command != .build;
    // A program `rig run` builds starts by creating the file
    // RIG_PROGRAM_STARTED names; `rig test`'s driver is its root instead.
    var pkg = try emitPackage(allocator, env, &graph, opts.command == .run);
    const root = if (opts.command == .@"test") test_driver else graph.root().out_basename;
    if (opts.command == .@"test") try pkg.files.append(allocator, .{ .path = test_driver, .contents = try testDriver(allocator, env, &graph) });

    const zig = env.zig();
    const verb = if (opts.command == .build) "build-exe" else "run";
    const flag = opts.mode.zigFlag();
    const libc: []const []const u8 = if (pkg.links_libc) &.{"-lc"} else &.{};
    // The package's directory, and Zig's cache for building it, which
    // keeps each package's builds apart from every other package's.
    var dir: []const u8 = undefined;
    var zig_cache: []const u8 = undefined;
    if (env.get("RIG_BUILD_STORE")) |store| {
        zig_cache = try storeEntry(allocator, io, store, &.{ zig, verb, flag, if (pkg.links_libc) "-lc" else "", root }, pkg.files.items);
        dir = try std.fs.path.join(allocator, &.{ zig_cache, "package" });
        try writeFile(io, try std.fs.path.join(allocator, &.{ zig_cache, "used" }), "");
    } else {
        dir = try outputDir(allocator, env, graph.root());
        zig_cache = try std.fs.path.join(allocator, &.{ dir, ".zig-cache" });
    }
    // A package in the cache home is held, under a shared lock, and
    // marked used before it is written; then old ones go.
    const in_cache_home = env.get("RIG_BUILD_STORE") == null and env.get("RIG_OUT_DIR") == null;
    const home = if (in_cache_home) try cacheHome(allocator, env) else null;
    if (home) |h| {
        tagCacheHome(io, h);
        holdPackage(allocator, io, dir);
    }
    try writePackage(allocator, io, dir, pkg.files.items);
    if (home) |h| trimCache(allocator, io, h, std.fs.path.basename(dir));

    const root_zig = try std.fs.path.join(allocator, &.{ dir, root });
    const emit_bin: []const []const u8 = if (opts.command == .build) &.{try allocator.print("-femit-bin={s}", .{opts.out_path orelse graph.root().name})} else &.{};
    const program_args: []const []const u8 = if (opts.command == .run) opts.program_args else &.{};
    const dashes: []const []const u8 = if (program_args.len > 0) &.{"--"} else &.{};
    const argv = try std.mem.concat(allocator, []const u8, &.{ &.{ zig, verb, flag, "--cache-dir", zig_cache, root_zig }, emit_bin, libc, dashes, program_args });
    if (opts.command == .build) {
        const code = try runZig(io, argv, null);
        if (code == 0) return;
        std.debug.print("note: emitted Zig is in {s}\n", .{dir});
        std.process.exit(code);
    }

    // The program creates `started`, a fresh path for each attempt, as it
    // starts (`rig.start` in the runtime): the evidence that the status
    // `zig run` returns is the program's and not Zig's. The program sees
    // RIG_PROGRAM_STARTED, never the caller's RIG_RUN_STARTED, so a `rig
    // run` it starts in turn cannot touch the caller's file.
    var environ = try env.map.clone(allocator);
    _ = environ.swapRemove(run_started_var);
    const started_dir = if (env.get("RIG_BUILD_STORE") != null)
        try std.fs.path.join(allocator, &.{ std.fs.path.dirname(zig_cache).?, ".started" })
    else
        dir;
    std.Io.Dir.cwd().createDirPath(io, started_dir) catch |err| notRun("cannot create `{s}`: {s}", .{ started_dir, @errorName(err) });
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        var name: [8]u8 = undefined;
        io.random(&name);
        const started = try std.fs.path.join(allocator, &.{ started_dir, try allocator.print(".started-{x}", .{&name}) });
        try environ.put(program_started_var, started);
        const ended = try runZigReport(io, argv, &environ);
        const code = ended.code;
        const ran = if (std.Io.Dir.cwd().statFile(io, started, .{})) |st| st.kind == .file else |_| false;
        std.Io.Dir.cwd().deleteFile(io, started) catch {};
        if (ran) {
            if (env.get(run_started_var)) |path| try writeFile(io, path, "");
            // A status above 128 may be the program's own; this says a
            // signal ended it (a Rig panic aborts, after its report).
            if (ended.signal) |sig| std.debug.print("error: rig: the program was killed by signal {d}\n", .{sig});
            if (code == 0) return;
            std.process.exit(code);
        }
        // A store entry whose manifests outlived the binary they name
        // (`h/` with no `o/*/<root>` executable, as an interrupted delete
        // leaves) sends Zig to run a binary that is gone: drop the
        // manifests so Zig builds again, once.
        if (attempt == 0 and env.get("RIG_BUILD_STORE") != null and exists(io, zig_cache, "h") and !hasBinary(allocator, io, zig_cache, root[0 .. root.len - ".zig".len])) {
            std.Io.Dir.cwd().deleteTree(io, try std.fs.path.join(allocator, &.{ zig_cache, "h" })) catch {};
            continue;
        }
        notRun("`zig run` exited with status {d}, and the program left no sign that it started", .{code});
    }
}

/// An executable `name` in any of the Zig cache's output directories.
fn hasBinary(allocator: std.mem.Allocator, io: std.Io, zig_cache: []const u8, name: []const u8) bool {
    const o = std.fs.path.join(allocator, &.{ zig_cache, "o" }) catch return false;
    var d = std.Io.Dir.cwd().openDir(io, o, .{ .iterate = true }) catch return false;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch return false) |entry| {
        if (entry.kind != .directory) continue;
        const path = std.fs.path.join(allocator, &.{ entry.name, name }) catch return false;
        const st = d.statFile(io, path, .{}) catch continue;
        if (st.kind == .file) return true;
    }
    return false;
}

fn exists(io: std.Io, dir: []const u8, name: []const u8) bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ dir, name }) catch return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// The module `rig test` builds: a driver next to the emitted ones that
/// runs the `__rig_tests` table of every module (see `rig.runTests`).
const test_driver = "__rig_test.zig";

fn testDriver(allocator: std.mem.Allocator, env: Env, graph: *const modules.ModuleGraph) ![]const u8 {
    var driver: std.Io.Writer.Allocating = .init(allocator);
    const w = &driver.writer;
    try w.print(
        \\const rig = @import("{s}");
        \\
        \\pub const panic = rig.panic;
        \\
    , .{emit.runtime_filename});
    try env.writeRootFlags(w, true);
    try w.writeAll(
        \\
        \\fn testsOf(comptime module: type) []const rig.Test {
        \\    return if (@hasDecl(module, "__rig_tests")) &module.__rig_tests else &.{};
        \\}
        \\
        \\pub fn main(init: @import("std").process.Init.Minimal) void {
        \\    rig.start(init);
        \\    rig.runTests(&.{
        \\
    );
    for (graph.modules.items, 0..) |m, i| {
        if (m.is_std) continue;
        try w.print("        .{{ .module = \"{s}\", .tests = testsOf(@import(\"{s}\")) }},\n", .{ if (i == 0) "" else m.name, m.out_basename });
    }
    try w.writeAll("    });\n}\n");
    return driver.written();
}

/// Run the Zig toolchain with inherited stdio (and `environ`, when given,
/// as its environment); return its exit code (128 + the signal number if
/// a signal ended it), which for `zig run` is the program's once it has
/// started it.
fn runZig(io: std.Io, argv: []const []const u8, environ: ?*const std.process.Environ.Map) !u8 {
    return (try runZigReport(io, argv, environ)).code;
}

const Ended = struct { code: u8, signal: ?u8 = null };

/// `runZig`, and the signal that ended the process, if one did (for
/// `zig run`, the program: Zig replaces itself with it).
fn runZigReport(io: std.Io, argv: []const []const u8, environ: ?*const std.process.Environ.Map) !Ended {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.FileNotFound => fatal("error: cannot run `{s}`: install Zig 0.17 and put it on PATH, or set ZIG", .{argv[0]}),
        else => return err,
    };
    return switch (try child.wait(io)) {
        .exited => |code| .{ .code = code },
        .signal => |sig| .{ .code = 128 +| @as(u8, @truncate(@backingInt(sig))), .signal = @truncate(@backingInt(sig)) },
        else => .{ .code = 1 },
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
    /// Every file of the package, by its path in the package directory:
    /// the runtime, each module, and the shims of the standard library.
    files: std.ArrayList(PackageFile),
    /// The root module's contents.
    root_source: []const u8,
    /// A module declares an `extern "c"`, which Zig links only with `-lc`.
    links_libc: bool,
};

const PackageFile = struct { path: []const u8, contents: []const u8 };

/// Emit the runtime and every module. With `RIG_LEAK_TRACE` or
/// `RIG_SANITIZE` set, the root module asks the runtime for stack-trace
/// leak reports or the sanitizer; with `RIG_SANITIZE`, emit also poisons
/// hidden storage when its scope ends. With `hook` (`rig run`), the root
/// module names the file the program creates as it starts.
fn emitPackage(allocator: std.mem.Allocator, env: Env, graph: *modules.ModuleGraph, hook: bool) !Package {
    var files: std.ArrayList(PackageFile) = .empty;
    try files.append(allocator, .{ .path = emit.runtime_filename, .contents = emit.runtime_source });

    var root_source: []const u8 = "";
    var links_libc = false;
    for (graph.modules.items, 0..) |*m, i| {
        var file_buffer: std.Io.Writer.Allocating = .init(allocator);
        var em = emit.Emitter.init(allocator, m.source, &file_buffer.writer, emit_facts.Facts.of(m.sema));
        defer em.deinit();
        em.poison = env.sanitize();
        try em.emit(m.ir);
        links_libc = links_libc or em.links_libc;
        if (i == 0 and (env.leakTrace() or env.sanitize() or hook)) {
            try file_buffer.writer.writeAll("\n");
            try env.writeRootFlags(&file_buffer.writer, hook);
        }
        try files.append(allocator, .{ .path = m.out_basename, .contents = file_buffer.written() });
        for (m.shims.items) |shim| try files.append(allocator, .{ .path = try std.fs.path.join(allocator, &.{ "rig", "std", shim.name }), .contents = shim.source });
        if (i == 0) root_source = file_buffer.written();
    }
    return .{ .files = files, .root_source = root_source, .links_libc = links_libc };
}

/// Write each file of a package into `dir`, leaving a file that already
/// holds the same contents untouched, so Zig's cache sees it unchanged.
fn writePackage(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, files: []const PackageFile) !void {
    for (files) |f| {
        const path = try std.fs.path.join(allocator, &.{ dir, f.path });
        if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(f.contents.len + 1))) |old| {
            if (std.mem.eql(u8, old, f.contents)) continue;
        } else |_| {}
        try writeFile(io, path, f.contents);
    }
}

/// The entry of `RIG_BUILD_STORE` for a package: a directory named by a
/// hash of the Zig command (`zig_args`) and every file's path and
/// contents, so the same package built the same way from any program or
/// checkout shares one entry. The entry is the package's Zig cache, and
/// holds the package in `package/` and the time of its last use in
/// `used`. The hash only chooses where to look: Zig still checks every
/// input of a cached build. Zig keys a cached build by the path of its
/// root module, relative to the current directory unless it lies in the
/// cache, which is why the package lives in the cache: a build from any
/// directory finds it.
fn storeEntry(allocator: std.mem.Allocator, io: std.Io, store: []const u8, zig_args: []const []const u8, files: []const PackageFile) ![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    const Part = struct {
        fn add(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
            var len: [8]u8 = undefined;
            std.mem.writeInt(u64, &len, bytes.len, .little);
            hash.update(&len);
            hash.update(bytes);
        }
    };
    Part.add(&h, "rig build store 1");
    for (zig_args) |arg| Part.add(&h, arg);
    for (files) |f| {
        Part.add(&h, f.path);
        Part.add(&h, f.contents);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    // The store may be a link to a directory elsewhere: resolve it first,
    // and create it only when it is not there.
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, store, allocator) catch real: {
        std.Io.Dir.cwd().createDirPath(io, store) catch |err| fatal("error: cannot create RIG_BUILD_STORE `{s}`: {s}", .{ store, @errorName(err) });
        break :real std.Io.Dir.cwd().realPathFileAlloc(io, store, allocator) catch |err| fatal("error: cannot find RIG_BUILD_STORE `{s}`: {s}", .{ store, @errorName(err) });
    };
    return std.fs.path.join(allocator, &.{ real, &std.fmt.bytesToHex(digest[0..16], .lower) });
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
    const base = (try cacheHome(allocator, env)) orelse fatal("error: set RIG_OUT_DIR, XDG_CACHE_HOME, or HOME for emitted Zig", .{});
    const project = try allocator.print("{s}-{x:0>16}", .{ root.name, std.hash.Wyhash.hash(0, root.path) });
    return std.fs.path.join(allocator, &.{ base, project });
}

/// Where `rig run` and `rig build` keep each program's package when
/// `$RIG_OUT_DIR` names no directory: `$XDG_CACHE_HOME/rig`, or
/// `~/.cache/rig`. A variable that is not an absolute path is ignored,
/// as the XDG Base Directory spec says, so a relative one never names a
/// directory under the current one. Null with neither usable.
fn cacheHome(allocator: std.mem.Allocator, env: Env) !?[]const u8 {
    if (env.get("XDG_CACHE_HOME")) |x| if (std.fs.path.isAbsolute(x)) return try std.fs.path.join(allocator, &.{ x, "rig" });
    if (env.get("HOME")) |home| if (std.fs.path.isAbsolute(home)) return try std.fs.path.join(allocator, &.{ home, ".cache", "rig" });
    return null;
}

/// How long a package directory in the cache home is kept unused, and
/// how often the cache home is trimmed of older ones.
const cache_keep_days = 5;
const cache_trim_days = 1;

/// The tag rig writes in a cache home it makes (https://bford.info/cachedir/),
/// which also tells backup tools to skip it. The trim and `rig clean`
/// act only on a home that holds it.
const cache_tag_name = "CACHEDIR.TAG";
const cache_tag_signature = "Signature: 8a477f597d28d172789f06886806bc55";
const cache_tag = cache_tag_signature ++ "\n# This file is a cache directory tag created by rig.\n# For information about cache directory tags, see https://bford.info/cachedir/\n";

/// The lock file in each package, which a run, build, or test holds a
/// shared lock on while it uses the package (`holdPackage`), and the
/// trim and `rig clean` an exclusive one while they remove it. The
/// system releases a lock when its process ends, however it ends.
const package_lock = ".lock";

/// What rig itself makes in the cache home, the only entries the trim
/// and `rig clean` remove. Anything else there is left alone.
const CacheEntry = enum {
    /// A program's package (`outputDir`): a directory named
    /// `<name>-<16 lowercase hex digits>` whose `rig` directory holds
    /// the runtime rig writes, none of them a link.
    package,
    /// A package being removed: a directory `.trash-<16 hex digits>`.
    trash,
    /// The empty file `.trimmed`, whose time is the last trim's.
    stamp,
    /// `CACHEDIR.TAG`, as rig writes it.
    tag,

    /// The kind of the entry `name` of `dir`, or null for anything rig
    /// did not make, a symbolic link included.
    fn of(dir: std.Io.Dir, io: std.Io, name: []const u8, kind: std.Io.File.Kind) ?CacheEntry {
        if (kind == .file and eql(name, ".trimmed")) {
            const st = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return null;
            return if (st.kind == .file and st.size == 0) .stamp else null;
        }
        if (kind == .file and eql(name, cache_tag_name)) return if (isTag(dir, io)) .tag else null;
        if (kind != .directory) return null;
        if (std.mem.startsWith(u8, name, ".trash-") and hexTail(name, ".trash-".len)) return .trash;
        if (name.len <= 17 or name[name.len - 17] != '-' or !hexTail(name, name.len - 16)) return null;
        var pd = dir.openDir(io, name, .{ .follow_symlinks = false }) catch return null;
        defer pd.close(io);
        const r = pd.statFile(io, "rig", .{ .follow_symlinks = false }) catch return null;
        if (r.kind != .directory) return null;
        const st = pd.statFile(io, emit.runtime_filename, .{ .follow_symlinks = false }) catch return null;
        return if (st.kind == .file) .package else null;
    }

    /// Whether `name` from `start` on is exactly 16 lowercase hex
    /// digits, as rig writes them.
    fn hexTail(name: []const u8, start: usize) bool {
        if (name.len != start + 16) return false;
        for (name[start..]) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
        return true;
    }
};

/// Whether `dir` holds rig's `CACHEDIR.TAG`, a regular file that starts
/// with the tag's signature.
fn isTag(dir: std.Io.Dir, io: std.Io) bool {
    const st = dir.statFile(io, cache_tag_name, .{ .follow_symlinks = false }) catch return false;
    if (st.kind != .file) return false;
    var buffer: [cache_tag_signature.len]u8 = undefined;
    const f = dir.openFile(io, cache_tag_name, .{ .follow_symlinks = false }) catch return false;
    defer f.close(io);
    const n = f.readPositionalAll(io, &buffer, 0) catch return false;
    return n == buffer.len and std.mem.eql(u8, &buffer, cache_tag_signature);
}

/// The cache home `home`, opened, when it is rig's: a directory, not a
/// link, that holds rig's tag. Null otherwise, with why in `why`.
fn openCacheHome(io: std.Io, home: []const u8, why: *[]const u8) ?std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, home, .{ .follow_symlinks = false }) catch {
        why.* = "missing";
        return null;
    };
    if (st.kind == .sym_link) {
        why.* = "it is a symbolic link, and rig removes files only in a cache directory it made";
        return null;
    }
    var d = cwd.openDir(io, home, .{ .iterate = true, .follow_symlinks = false }) catch {
        why.* = "it cannot be opened";
        return null;
    };
    if (!isTag(d, io)) {
        d.close(io);
        why.* = "it holds no " ++ cache_tag_name ++ " from rig, so rig did not make it";
        return null;
    }
    return d;
}

/// Write rig's tag in the cache home `home` when rig makes it, or when
/// it holds nothing but rig's own entries (a home an earlier rig made
/// before it wrote tags). A home with anything else in it, or that is a
/// link, stays untagged, so the trim and `rig clean` leave it alone.
fn tagCacheHome(io: std.Io, home: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, home, .{ .follow_symlinks = false }) catch {
        cwd.createDirPath(io, home) catch return;
        writeTag(io, home);
        return;
    };
    if (st.kind != .directory) return;
    var d = cwd.openDir(io, home, .{ .iterate = true, .follow_symlinks = false }) catch return;
    defer d.close(io);
    if (d.statFile(io, cache_tag_name, .{ .follow_symlinks = false })) |_| return else |_| {}
    var it = d.iterate();
    while (it.next(io) catch return) |entry| if (CacheEntry.of(d, io, entry.name, entry.kind) == null) return;
    writeTag(io, home);
}

fn writeTag(io: std.Io, home: []const u8) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ home, cache_tag_name }) catch return;
    var file = std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = false }) catch return;
    defer file.deinit(io);
    file.file.writeStreamingAll(io, cache_tag) catch return;
    file.link(io) catch {};
}

/// Make the package directory `dir` and hold a shared lock on its lock
/// file until this process ends, so no trim or `rig clean` removes it
/// while it is written or its program runs; then mark it used. A lock
/// taken on a package a trim renamed away meanwhile is let go, and the
/// package made again. Where the system has no file locks, the package
/// is used unlocked (and no trim runs: `lockForRemoval`).
fn holdPackage(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    const path = std.fs.path.join(allocator, &.{ dir, package_lock }) catch return;
    for (0..8) |_| {
        cwd.createDirPath(io, dir) catch return;
        const f = cwd.createFile(io, path, .{ .truncate = false }) catch return;
        f.lock(io, .shared) catch {
            f.close(io);
            break;
        };
        const held = f.stat(io) catch break;
        const now = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch {
            f.close(io);
            continue;
        };
        if (now.inode == held.inode) break;
        f.close(io);
    }
    cwd.setTimestampsNow(io, dir, .{}) catch {};
}

/// The lock file of the package `name` of `dir`, locked exclusively, or
/// null when a run, build, or test holds it (or it is no regular file).
/// `error.FileLocksUnsupported` where the system has no file locks: no
/// trim or clean can know a package is unused there.
/// `created` says whether it made the lock file, which a package an
/// earlier rig made lacks, and so changed the package's time.
fn lockForRemoval(io: std.Io, dir: std.Io.Dir, name: []const u8, created: *bool) error{FileLocksUnsupported}!?std.Io.File {
    var pd = dir.openDir(io, name, .{ .follow_symlinks = false }) catch return null;
    defer pd.close(io);
    created.* = false;
    if (pd.createFile(io, package_lock, .{ .exclusive = true })) |f| {
        f.close(io);
        created.* = true;
    } else |_| {}
    const f = pd.openFile(io, package_lock, .{ .follow_symlinks = false }) catch return null;
    const locked = f.tryLock(io, .exclusive) catch |err| {
        f.close(io);
        return if (err == error.FileLocksUnsupported) error.FileLocksUnsupported else null;
    };
    if (!locked) {
        f.close(io);
        return null;
    }
    return f;
}

/// The time the package `name` of `dir` was last used: its own time,
/// which a run sets (`holdPackage`).
fn lastUsed(dir: std.Io.Dir, io: std.Io, name: []const u8) ?std.Io.Timestamp {
    const st = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return null;
    return st.mtime;
}

/// Whether a package last used at `used` is unused by the clock read
/// now: older than `cache_keep_days`. A time in the future is fresh.
fn unusedSince(io: std.Io, used: ?std.Io.Timestamp) bool {
    const t = used orelse return false;
    return t.durationTo(std.Io.Timestamp.now(io, .real)).nanoseconds >= cache_keep_days * std.time.ns_per_day;
}

/// What became of an entry the trim or `rig clean` set out to remove.
const Removal = enum { removed, gone, busy, kept, unsupported };

/// Remove `name` of `dir`. A package is locked exclusively first (a
/// package in use is `busy`), checked again, with `aged`, to be unused
/// by its time read under the lock (or, where taking the lock made its
/// lock file, the time before), and renamed out of the way in one step
/// under the lock, so a run never meets one half removed; then deleted.
/// `gone` when another process removed it first.
fn removeEntry(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, kind: CacheEntry, aged: bool) Removal {
    switch (kind) {
        .stamp, .tag => {
            dir.deleteFile(io, name) catch |err| return if (err == error.FileNotFound) .gone else .kept;
            return .removed;
        },
        .trash => {
            dir.deleteTree(io, name) catch return .kept;
            return .removed;
        },
        .package => {
            const before = lastUsed(dir, io, name);
            var created = false;
            const lock = (lockForRemoval(io, dir, name, &created) catch return .unsupported) orelse
                return if (dir.statFile(io, name, .{ .follow_symlinks = false })) |_| .busy else |_| .gone;
            if (aged and !unusedSince(io, if (created) before else lastUsed(dir, io, name))) {
                lock.close(io);
                return .kept;
            }
            var tag: [8]u8 = undefined;
            io.random(&tag);
            const gone = allocator.print(".trash-{x}", .{&tag}) catch {
                lock.close(io);
                return .kept;
            };
            dir.rename(name, dir, gone, io) catch |err| {
                lock.close(io);
                return if (err == error.FileNotFound) .gone else .kept;
            };
            lock.close(io);
            dir.deleteTree(io, gone) catch {};
            return .removed;
        },
    }
}

/// Remove the packages in the cache home `home` that no run or build has
/// used for `cache_keep_days`, all but `current` and any a run, build,
/// or test holds (`holdPackage`), and what an interrupted trim left. It
/// acts only on a home rig made (`openCacheHome`). A stamp, `.trimmed`,
/// records the last trim, so this reads the directory at most once in
/// `cache_trim_days`; a stamp dated in the future counts as old. Each
/// package's time is checked again, under its lock, just before it goes.
/// One line on stderr says how many went. Where the system has no file
/// locks, nothing is removed. A failure never fails the build.
fn trimCache(allocator: std.mem.Allocator, io: std.Io, home: []const u8, current: []const u8) void {
    var why: []const u8 = "";
    var d = openCacheHome(io, home, &why) orelse return;
    defer d.close(io);
    const now = std.Io.Timestamp.now(io, .real);
    if (d.statFile(io, ".trimmed", .{ .follow_symlinks = false })) |st| {
        if (st.kind != .file or st.size != 0) return;
        const age = st.mtime.durationTo(now).nanoseconds;
        if (age >= 0 and age < cache_trim_days * std.time.ns_per_day) return;
        d.setTimestampsNow(io, ".trimmed", .{ .follow_symlinks = false }) catch return;
    } else |_| {
        const file = d.createFile(io, ".trimmed", .{ .exclusive = true }) catch return;
        file.close(io);
    }
    var old: std.ArrayList(struct { name: []const u8, kind: CacheEntry }) = .empty;
    var it = d.iterate();
    while (it.next(io) catch return) |entry| {
        if (eql(entry.name, current)) continue;
        const kind = CacheEntry.of(d, io, entry.name, entry.kind) orelse continue;
        if (kind == .stamp or kind == .tag or (kind == .package and !unusedSince(io, lastUsed(d, io, entry.name)))) continue;
        old.append(allocator, .{ .name = allocator.dupe(u8, entry.name) catch return, .kind = kind }) catch return;
    }
    var removed: usize = 0;
    for (old.items) |e| switch (removeEntry(allocator, io, d, e.name, e.kind, true)) {
        .removed => removed += @intFromBool(e.kind == .package),
        .unsupported => break,
        else => {},
    };
    if (removed > 0) std.debug.print("rig: removed {d} package{s} unused for {d} days from {s}\n", .{ removed, if (removed == 1) "" else "s", cache_keep_days, home });
}

/// `rig clean`: remove what rig made in its cache home, every program's
/// package and Zig cache, but a package a run, build, or test holds;
/// then the home itself, with its tag, if nothing else is in it. A home
/// rig did not make (no tag, or a link) is left alone. `$RIG_OUT_DIR`
/// and `$RIG_BUILD_STORE` are their callers'.
fn clean(allocator: std.mem.Allocator, io: std.Io, env: Env) void {
    const home = (cacheHome(allocator, env) catch fatal("error: out of memory", .{})) orelse fatal("error: set XDG_CACHE_HOME or HOME to an absolute path to name the cache", .{});
    var why: []const u8 = "";
    var d = openCacheHome(io, home, &why) orelse {
        if (eql(why, "missing")) {
            printOut(io, "rig: nothing to clean in {s}\n", .{home});
            return;
        }
        fatal("error: rig: not cleaning {s}: {s}", .{ home, why });
    };
    var found: std.ArrayList(struct { name: []const u8, kind: CacheEntry }) = .empty;
    var others = false;
    var it = d.iterate();
    while (it.next(io) catch |err| fatal("error: cannot read `{s}`: {s}", .{ home, @errorName(err) })) |entry| {
        const kind = CacheEntry.of(d, io, entry.name, entry.kind) orelse {
            others = true;
            continue;
        };
        if (kind == .stamp or kind == .tag) continue;
        found.append(allocator, .{ .name = allocator.dupe(u8, entry.name) catch fatal("error: out of memory", .{}), .kind = kind }) catch fatal("error: out of memory", .{});
    }
    var removed: usize = 0;
    var busy: usize = 0;
    var kept = false;
    for (found.items) |e| switch (removeEntry(allocator, io, d, e.name, e.kind, false)) {
        .removed, .gone => removed += @intFromBool(e.kind == .package),
        .busy => busy += 1,
        .kept => kept = true,
        .unsupported => fatal("error: rig: not cleaning {s}: this system has no file locks, so rig cannot tell which packages are in use", .{home}),
    };
    printOut(io, "rig: removed {d} package{s} from {s}\n", .{ removed, if (removed == 1) "" else "s", home });
    if (busy > 0) printOut(io, "rig: kept {d} package{s} a run, build, or test is using\n", .{ busy, if (busy == 1) "" else "s" });
    if (kept) printOut(io, "rig: kept some of rig's files in {s}, which could not be removed\n", .{home});
    if (others) printOut(io, "rig: kept {s}, which holds files rig did not make\n", .{home});
    if (others or busy > 0 or kept) {
        d.close(io);
        return;
    }
    _ = removeEntry(allocator, io, d, ".trimmed", .stamp, false);
    _ = removeEntry(allocator, io, d, cache_tag_name, .tag, false);
    d.close(io);
    std.Io.Dir.cwd().deleteDir(io, home) catch {};
}

// The unit tests of every compiler file, and of the runtime.
test {
    _ = rig;
    _ = diag;
    _ = modules;
    _ = emit;
    _ = emit_facts;
    _ = sema;
    _ = @import("ownership.zig");
    _ = @import("runtime.zig");
}
