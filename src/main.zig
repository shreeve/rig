//! Rig compiler CLI. `usage` below is the reference; docs/INTERNALS.md
//! describes the pipeline behind each command.
//!
//! `run`, `build`, `test`, and `emit` never emit a program the checkers
//! reject. They write the emitted package (one `.zig` file per module
//! plus the runtime in `rig/`) to the output directory, then hand it to
//! the Zig toolchain.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const parser = @import("parser.zig");
const ir = parser.ir;
const rig = @import("rig.zig");
const diag = @import("diag.zig");
const emit = @import("emit.zig");
const symbols = @import("symbols.zig");
const inlining = @import("inlining.zig");
const timing = @import("timing.zig");
const emit_facts = @import("facts.zig");
const modules = @import("modules.zig");
const sema = @import("sema.zig");
const proofs = @import("proofs.zig");
const lsp = @import("lsp.zig");

const usage =
    \\Rig: a systems language with visible ownership, compiled to Zig.
    \\
    \\Usage: rig <command> [options] <file.rig>
    \\       rig run [options] <file.rig> -- <program arguments>
    \\       rig batch build [--release[=safe|fast]] <dir> <file.rig>...
    \\       rig batch run <dir> <n>
    \\       rig clean
    \\       rig lsp
    \\
    \\Commands:
    \\  check     Check the program and its imports
    \\  run       Check, build, and run the program
    \\  build     Check and build a native executable
    \\  test      Check, build, and run the program's `test` blocks,
    \\            deterministically (`--seed`)
    \\  emit      Check, then print the root module's Zig to stdout
    \\  batch     Build many programs into one executable, <dir>/bin, with
    \\            one copy of the runtime (build), and run program <n> of it
    \\            as `run` runs a program (run): test/batch.rip's runner
    \\  clean     Remove the programs rig built in its cache (see RIG_OUT_DIR)
    \\  lsp       Serve the language server protocol on stdin and stdout, for
    \\            an editor (editors/README.md)
    \\
    \\Options:
    \\  --tests                Check what `rig test` builds: for a directory
    \\                         module, its `*_test.rig` files too (check)
    \\  --facts                Print the root module's syntax facts after
    \\                         checking it (check): every IR node with its
    \\                         kind, span, and role-named children
    \\  --facts=sema           Print the facts sema recorded for the root
    \\                         module's expressions instead (check)
    \\  --facts=storage        Print the hidden storage emit makes for the
    \\                         root module instead (check)
    \\  --facts=proofs         Print the tests of the root module that are
    \\                         known to pass, which emit omits (check)
    \\  --facts=frames         Print each frame owner of the root module
    \\                         (a function, closure, test, or drop body)
    \\                         with its account: the bytes of values it
    \\                         keeps on its stack, as the frame check counts
    \\                         them, its reach, what the calls of functions
    \\                         marked `inline` land in it, and what the
    \\                         functions the compiler inlines add (check)
    \\  --time                 Print the time each pass of the compiler
    \\                         takes, summed over the modules (check)
    \\  --release[=safe|fast]  Optimize (run, build, test): `--release` and
    \\                         `--release=safe` are Zig's safe mode, which
    \\                         keeps overflow and bounds checks;
    \\                         `--release=fast` is its fast mode. Default:
    \\                         debug, leak-checked.
    \\  --seed=<n>             Run deterministically with seed n (run, test):
    \\                         on one thread, with a virtual clock that
    \\                         sleeps take no time on, the seed choosing
    \\                         which ready task runs next, so the same seed
    \\                         runs the same way again. `rig test` runs so
    \\                         with seed 1 unless given one
    \\  --seeds=<k>            Run the tests with each seed from 1 to k,
    \\                         stopping at the first that fails (test)
    \\  -o <path>              Executable to write (build; default ./<name>)
    \\  -h, --help             Show this help
    \\  -V, --version          Show the version
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
    \\  RIG_CACHE_MAX_GB The most gigabytes that cache holds (default 10;
    \\                   0 for no limit): over it, the least recently
    \\                   used directories go, checked every run and
    \\                   trimmed at most every 10 minutes
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
    \\  RIG_SEED         A program started with it set runs as `--seed`
    \\                   does, with that seed
    \\  RIG_LEAK_TRACE   Set to 1 when building to report each leaked
    \\                   allocation with its stack trace (slower)
    \\  RIG_SANITIZE     Set to 1 when building a Debug program to make
    \\                   any use of freed memory crash where it happens
    \\                   (much slower; the test suite sets it)
    \\  RIG_NO_PROOFS    Set to 1 to make every test, as if the compiler
    \\                   proved none: the differential run of the proofs
    \\  RIG_VERIFY_PROOFS
    \\                   Set to 1 when building with --release to make
    \\                   the tests the compiler proved, and omits, as
    \\                   assertions, as every debug build does
    \\  RIG_STRICT_OPTIONALS
    \\                   Set to 1 to hold every object's optional as a
    \\                   tagged struct, so a program compiles only if the
    \\                   compiler writes every operation on one through
    \\                   the runtime's optional helpers: a test of the
    \\                   compiler
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

/// What `check --facts` prints: the IR's syntax facts, sema's, the
/// hidden storage emit makes, the tests known to pass, or each frame's
/// counted bytes.
const Facts = enum { none, syntax, sema, storage, proofs, frames };

const Options = struct {
    command: Command,
    path: []const u8,
    mode: Mode = .debug,
    out_path: ?[]const u8 = null,
    facts: Facts = .none,
    /// `check --time`: print the time of each pass.
    time: bool = false,
    /// `rig check --tests`: check the program as `rig test` builds it.
    tests: bool = false,
    /// `rig run file.rig -- args...`: the program's own arguments.
    program_args: []const []const u8 = &.{},
    /// `--seed=n`: run deterministically with seed `n` (run, test).
    seed: ?u64 = null,
    /// `rig test --seeds=k`: run the tests with each seed from 1 to `k`.
    seeds: ?u64 = null,
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

    fn verifyProofs(env: Env) bool {
        return env.flag("RIG_VERIFY_PROOFS");
    }

    /// Set, and not to `0`.
    fn flag(env: Env, name: []const u8) bool {
        const value = env.get(name) orelse return false;
        return !std.mem.eql(u8, value, "0");
    }

    /// The declarations that ask the runtime for leak traces, the
    /// sanitizer, or the assertions of proven tests, written into the root
    /// module (`runtime.zig`); those that run a program's tasks on the
    /// scheduler, with the guard below each task's stack (`tasks`,
    /// `taskGuardOf`); and, in a
    /// package `rig run` or `rig test` builds (`hook`), the variable
    /// naming the file the program creates as it starts (`buildCommand`).
    fn writeRootFlags(env: Env, w: *std.Io.Writer, hook: bool, tasks: ?u64) !void {
        if (tasks) |guard| try w.print("pub const __rig_tasks = true;\npub const __rig_task_guard: usize = {d};\n", .{guard});
        if (env.leakTrace()) try w.writeAll("pub const __rig_leak_trace = true;\n");
        if (env.sanitize()) try w.writeAll("pub const __rig_sanitize = true;\n");
        if (env.verifyProofs()) try w.writeAll("pub const __rig_verify_proofs = true;\n");
        if (hook) try w.writeAll("pub const __rig_run_started = \"" ++ program_started_var ++ "\";\n");
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const env: Env = .{ .map = init.environ_map };
    const args = try init.minimal.args.toSlice(allocator);
    // `rig lsp` serves an editor until it says `exit`.
    if (args.len > 1 and eql(args[1], "lsp")) {
        for (args[2..]) |arg| if (!eql(arg, "--stdio")) usageError("`rig lsp` takes no arguments; it serves on stdin and stdout", .{});
        std.process.exit(lsp.run(io, init.environ_map));
    }
    if (args.len > 1 and eql(args[1], "batch")) std.process.exit(try batchCommand(allocator, io, env, args[2..]));
    const opts = parseArgs(io, args[@min(1, args.len)..]);

    switch (opts.command) {
        .clean => clean(allocator, io, env),
        .tokens, .parse, .normalize => {
            const source = std.Io.Dir.cwd().readFileAlloc(io, opts.path, allocator, .limited(modules.max_source_bytes + 1)) catch |err|
                fatal("error: cannot read `{s}`: {s}", .{ opts.path, modules.fileError(err) });
            switch (opts.command) {
                .tokens => try dumpTokens(io, opts.path, source),
                .parse => try printTree(allocator, io, opts.path, source, .raw),
                .normalize => try printTree(allocator, io, opts.path, source, .semantic),
                else => unreachable,
            }
        },
        .check => {
            var times: timing.Timing = .{ .io = io };
            var graph = try loadProject(allocator, io, env, opts.path, opts.tests, if (opts.time) &times else null);
            defer graph.deinit();
            switch (opts.facts) {
                .none => {},
                .syntax => try printFacts(io, graph.root()),
                .frames => {
                    const m = graph.root();
                    var buffer: [4096]u8 = undefined;
                    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
                    // Each frame owner's account: its own bytes and reach
                    // (`?` where no count knows them), the reach of what
                    // the calls of marked `inline` functions land in it,
                    // and what the functions the rule inlines into it add.
                    for (m.sema.frame_owners.items, 0..) |o, i| {
                        const at = diag.lineCol(m.source, o.pos);
                        const acc = m.sema.account(@intCast(i));
                        if (acc.own) |own| {
                            try writer.interface.print("{d}:{d} {s} {d} {d} {d} {d}\n", .{ at.line, at.col, o.label, own.bytes, own.reach, acc.marked.reach, acc.auto });
                        } else try writer.interface.print("{d}:{d} {s} ? ? {d} {d}\n", .{ at.line, at.col, o.label, acc.marked.reach, acc.auto });
                    }
                    try writer.interface.flush();
                },
                .sema, .storage, .proofs => {
                    const m = graph.root();
                    var buffer: [4096]u8 = undefined;
                    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
                    switch (opts.facts) {
                        .sema => try sema.writeFactsDump(m.sema, allocator, m.ir, &writer.interface),
                        .storage => try sema.writeStorageDump(m.sema, allocator, m.ir, &writer.interface),
                        else => try proofs.writeDump(m.sema, allocator, m.ir, &writer.interface),
                    }
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
    var time = false;
    var seed: ?u64 = null;
    var seeds: ?u64 = null;
    var tests = false;
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
        } else if (eql(arg, "-V") or eql(arg, "--version") or (first and eql(arg, "version"))) {
            printOut(io, "rig {s}\n", .{build_options.version});
            std.process.exit(0);
        } else if (eql(arg, "--release") or eql(arg, "--release=safe")) {
            mode = .safe;
        } else if (eql(arg, "--release=fast")) {
            mode = .fast;
        } else if (eql(arg, "--tests")) {
            tests = true;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            seed = std.fmt.parseInt(u64, arg["--seed=".len..], 10) catch usageError("`--seed` takes a whole number: `--seed=7`", .{});
        } else if (std.mem.startsWith(u8, arg, "--seeds=")) {
            seeds = std.fmt.parseInt(u64, arg["--seeds=".len..], 10) catch usageError("`--seeds` takes a count of seeds: `--seeds=20`", .{});
            if (seeds.? == 0) usageError("`--seeds` takes a count of seeds, at least 1: `--seeds=20`", .{});
        } else if (eql(arg, "--facts")) {
            facts = .syntax;
        } else if (eql(arg, "--facts=sema")) {
            facts = .sema;
        } else if (eql(arg, "--facts=storage")) {
            facts = .storage;
        } else if (eql(arg, "--facts=proofs")) {
            facts = .proofs;
        } else if (eql(arg, "--facts=frames")) {
            facts = .frames;
        } else if (eql(arg, "--time")) {
            time = true;
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
    if (time and cmd != .check) usageError("`--time` applies to check", .{});
    if (tests and cmd != .check) usageError("`--tests` applies to check; `rig test` builds the tests already", .{});
    if (seed != null and cmd != .run and cmd != .@"test") usageError("`--seed` applies to run and test", .{});
    if (seeds != null and cmd != .@"test") usageError("`--seeds` applies to test", .{});
    if (seed != null and seeds != null) usageError("give `--seed` for one seed or `--seeds` for several, not both", .{});
    if (cmd == .clean) {
        if (path != null) usageError("`rig clean` takes no file", .{});
        return .{ .command = cmd, .path = "" };
    }
    const file = path orelse usageError("`rig {s}` needs a .rig file", .{@tagName(cmd)});
    // `rig check` and `rig test` also take a directory module.
    const directory = (cmd == .check or cmd == .@"test") and isDirectory(io, file);
    // `rig build` writes ./<name>: a file without `.rig` would be its own
    // output.
    const base = std.fs.path.basename(file);
    if (!directory and (!std.mem.endsWith(u8, base, ".rig") or base.len == ".rig".len)) usageError("`{s}` is not a .rig file", .{file});
    // Every source file ends in `.rig`, so an executable never replaces
    // one, even where file names ignore case.
    if (out_path) |o| if (std.ascii.endsWithIgnoreCase(o, ".rig")) usageError("`-o {s}` would write the executable over a .rig file", .{o});
    return .{ .command = cmd, .path = file, .mode = mode, .out_path = out_path, .facts = facts, .time = time, .tests = tests, .program_args = program_args, .seed = seed, .seeds = seeds };
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
            try diag.write(&.{.{ .severity = .@"error", .pos = tok.pos, .end = rig.endOf(&lexer.base, tok), .message = lexer.err.message() }}, source, path, &err_writer.interface);
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
    try rig.writeTree(tree, source, &writer.interface);
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

/// Load and check the project rooted at `path`, with the root's test
/// files, if it is a directory module, when `with_tests`; print every
/// diagnostic and exit 1 if there are errors.
/// With `times`, add each pass's time to it and print them after the
/// diagnostics.
fn loadProject(allocator: std.mem.Allocator, io: std.Io, env: Env, path: []const u8, with_tests: bool, times: ?*timing.Timing) !modules.ModuleGraph {
    return (try loadChecked(allocator, io, env, path, with_tests, times)) orelse std.process.exit(1);
}

/// The program at `path`, checked, or `null` when the checkers reject it,
/// once its diagnostics are on stderr.
fn loadChecked(allocator: std.mem.Allocator, io: std.Io, env: Env, path: []const u8, with_tests: bool, times: ?*timing.Timing) !?modules.ModuleGraph {
    const t0 = timing.start(times);
    var graph = modules.ModuleGraph.init(allocator, io);
    errdefer graph.deinit();
    graph.std_dir = env.get("RIG_STD");
    graph.with_tests = with_tests;
    graph.timing = times;
    try graph.loadRoot(path);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    // Inlining is decided for a program with no errors, and reports a
    // cycle of marked `inline` functions, which Zig cannot inline.
    if (!graph.hasErrors()) {
        const t1 = timing.start(times);
        try inlining.decide(allocator, &graph, inlining.max_size);
        timing.stop(times, .inlining, t1);
        try graph.markTextTables();
    }
    try graph.writeAllDiagnostics(&writer.interface);
    try writer.interface.flush();
    const failed = graph.hasErrors();
    if (times) |t| {
        try t.write(&writer.interface, @intCast(@max(t0.?.durationTo(t.now()).nanoseconds, 0)));
        try writer.interface.flush();
    }
    if (failed) {
        graph.deinit();
        return null;
    }
    return graph;
}

/// `rig emit`: the root module's Zig on stdout; the whole package
/// (imports and runtime) is written to the output directory.
fn emitCommand(allocator: std.mem.Allocator, io: std.Io, env: Env, path: []const u8) !void {
    var graph = try loadProject(allocator, io, env, path, false, null);
    defer graph.deinit();
    const pkg = try emitPackage(allocator, env, &graph, .{});
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
    var graph = try loadProject(allocator, io, env, opts.path, opts.command == .@"test", null);
    defer graph.deinit();
    if (opts.command != .@"test" and !declaresMain(graph.root())) fatal("{s}:1:1: error: no `sub main()` to run", .{graph.root().display});
    program_pending = opts.command != .build;
    // A program `rig run` builds starts by creating the file
    // RIG_PROGRAM_STARTED names; `rig test`'s driver is its root instead.
    var pkg = try emitPackage(allocator, env, &graph, .{ .hook = opts.command == .run });
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
    if (home) |h| trimCache(allocator, io, h, std.fs.path.basename(dir), cacheCap(env));

    const root_zig = try std.fs.path.join(allocator, &.{ dir, root });
    const out = opts.out_path orelse graph.root().name;
    const emit_bin: []const []const u8 = if (opts.command == .build) &.{try allocator.print("-femit-bin={s}", .{out})} else &.{};
    const program_args: []const []const u8 = if (opts.command == .run) opts.program_args else &.{};
    const dashes: []const []const u8 = if (program_args.len > 0) &.{"--"} else &.{};
    const argv = try std.mem.concat(allocator, []const u8, &.{ &.{ zig, verb, flag, "--cache-dir", zig_cache, root_zig }, emit_bin, libc, dashes, program_args });
    if (opts.command == .build) {
        // `zig build-exe` keeps no cache of its own for an output it is
        // told to write: the same build again copies the executable the
        // last one kept (`keptBuild`), and Zig is not run.
        const zig_args = try std.mem.concat(allocator, []const u8, &.{ &.{ zig, verb, flag, "--cache-dir", zig_cache, root_zig }, libc });
        const kept = try keptBuild(allocator, io, env, zig_cache, opts.mode, out, zig_args, pkg.files.items);
        if (kept) |k| if (reuseBuild(allocator, io, k, out)) {
            if (home) |h| recordSize(allocator, io, h, dir);
            return;
        };
        const objects_before = if (kept != null) zigObjects(allocator, io, zig_cache) else &.{};
        const code = try runZig(io, argv);
        if (code == 0) if (kept) |k| keepBuild(allocator, io, k, out, zig_cache, objects_before);
        if (home) |h| recordSize(allocator, io, h, dir);
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
    // The seed a deterministic run takes: `--seed`, or for `rig test`
    // the caller's RIG_SEED, else 1; `--seeds=k` runs seeds 1 to k in
    // turn, stopping at the first run that fails.
    const testing = opts.command == .@"test";
    const first_seed: ?u64 = opts.seed orelse if (opts.seeds != null) 1 else if (testing) (if (env.get("RIG_SEED")) |v| std.fmt.parseInt(u64, v, 10) catch 1 else 1) else null;
    const last_seed: ?u64 = opts.seeds orelse first_seed;
    var seed = first_seed;
    while (true) : (seed = seed.? + 1) {
        if (seed) |s| try environ.put("RIG_SEED", try allocator.print("{d}", .{s}));
        try runStarted(allocator, io, env, &environ, argv, started_dir, home, dir, zig_cache, root);
        if (seed == null or seed.? >= last_seed.?) return;
    }
}

/// Run the program `rig run` or `rig test` built, by `argv`, with
/// `environ`, until it is seen to start (`program_started_var`); exit
/// with its status when it fails, and return when it succeeds.
fn runStarted(allocator: std.mem.Allocator, io: std.Io, env: Env, environ: *std.process.Environ.Map, argv: []const []const u8, started_dir: []const u8, home: ?[]const u8, dir: []const u8, zig_cache: []const u8, root: []const u8) !void {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        var name: [8]u8 = undefined;
        io.random(&name);
        const started = try std.fs.path.join(allocator, &.{ started_dir, try allocator.print(".started-{x}", .{&name}) });
        try environ.put(program_started_var, started);
        const ended = try runZigReport(io, argv, environ);
        const code = ended.code;
        const ran = if (std.Io.Dir.cwd().statFile(io, started, .{})) |st| st.kind == .file else |_| false;
        std.Io.Dir.cwd().deleteFile(io, started) catch {};
        if (home) |h| recordSize(allocator, io, h, dir);
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

/// `rig batch build [--release[=safe|fast]] DIR FILE...` builds every
/// program into one executable, `DIR/bin`, with one Zig compile and one
/// copy of the runtime: each program's package goes to `DIR/pN` (`N` its
/// place among the files), the runtime once to `DIR/rig/runtime.zig` as
/// the Zig module `rig`, and `DIR/main.zig` starts program `N` when its
/// first argument is `N`, handing the program the rest. A file the checkers reject, or with no `sub
/// main()`, is left out, with its diagnostics on stderr. `DIR/programs`
/// lists the programs built, `N<TAB>FILE` a line. The status is Zig's, or
/// 1 when no program could be built. `DIR/inputs` holds a hash of every
/// file of the batch, how Zig builds it, and which Zig (`zigIdentity`):
/// when it matches and `DIR/bin` is there, the batch is built already,
/// and Zig is not run (`zig build-exe` keeps no cache of its own for an
/// output it is told to write).
///
/// `rig batch run DIR N` runs program `N` of that executable as `rig run`
/// runs a program: its status, and RIG_RUN_STARTED created only once it
/// has started.
fn batchCommand(allocator: std.mem.Allocator, io: std.Io, env: Env, args: []const []const u8) !u8 {
    const what = if (args.len > 0) args[0] else "";
    if (eql(what, "run")) {
        if (args.len != 3) usageError("`rig batch run` takes a directory and a program's number", .{});
        return batchRun(allocator, io, env, args[1], args[2]);
    }
    if (!eql(what, "build")) usageError("`rig batch` is `rig batch build` or `rig batch run`", .{});
    var mode: Mode = .debug;
    var i: usize = 1;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (eql(args[i], "--release") or eql(args[i], "--release=safe")) {
            mode = .safe;
        } else if (eql(args[i], "--release=fast")) {
            mode = .fast;
        } else usageError("unknown option `{s}`", .{args[i]});
    }
    if (args.len < i + 2) usageError("`rig batch build` takes a directory and at least one .rig file", .{});
    const dir = args[i];
    const files = args[i + 1 ..];

    var list: std.Io.Writer.Allocating = .init(allocator);
    var root: std.Io.Writer.Allocating = .init(allocator);
    try root.writer.print(
        \\const std = @import("std");
        \\const rig = @import("{s}");
        \\
        \\pub const panic = rig.panic;
        \\
    , .{emit.runtime_module});
    try env.writeRootFlags(&root.writer, true, null);
    try root.writer.writeAll("\nconst programs = .{\n");
    var links_libc = false;
    var makes_tasks = false;
    var largest_frame: u64 = 0;
    var built: usize = 0;
    var inputs = std.crypto.hash.sha2.Sha256.init(.{});
    const Part = struct {
        fn add(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
            var len: [8]u8 = undefined;
            std.mem.writeInt(u64, &len, bytes.len, .little);
            hash.update(&len);
            hash.update(bytes);
        }
    };
    Part.add(&inputs, "rig batch 1");
    for (files, 0..) |file, n| {
        var graph = (loadChecked(allocator, io, env, file, false, null) catch |err| {
            std.debug.print("error: cannot load `{s}`: {s}\n", .{ file, @errorName(err) });
            continue;
        }) orelse continue;
        defer graph.deinit();
        if (!declaresMain(graph.root())) {
            std.debug.print("{s}:1:1: error: no `sub main()` to run\n", .{graph.root().display});
            continue;
        }
        const pkg = try emitPackage(allocator, env, &graph, .{ .batch = true });
        links_libc = links_libc or pkg.links_libc;
        makes_tasks = makes_tasks or makesTasks(&graph);
        largest_frame = @max(largest_frame, largestFrame(&graph));
        const sub = try allocator.print("p{d}", .{n});
        try writePackage(allocator, io, try std.fs.path.join(allocator, &.{ dir, sub }), pkg.files.items);
        for (pkg.files.items) |f| {
            Part.add(&inputs, sub);
            Part.add(&inputs, f.path);
            Part.add(&inputs, f.contents);
        }
        try list.writer.print("{d}\t{s}\n", .{ n, file });
        try root.writer.print("    .{{ {d}, @import(\"{s}/{s}\") }},\n", .{ n, sub, graph.root().out_basename });
        built += 1;
    }
    if (built == 0) {
        std.debug.print("error: rig batch: no program to build\n", .{});
        return 1;
    }
    try root.writer.writeAll("};\n");
    // One runtime serves the batch: it runs tasks if any program makes them.
    if (makes_tasks) try root.writer.print("\npub const __rig_tasks = true;\npub const __rig_task_guard: usize = {d};\n", .{sema.taskGuard(largest_frame)});
    try root.writer.print(
        \\
        \\// The first argument names the program; it sees the others, after
        \\// the executable's path, as `rig run` would give them. A program whose
        \\// `main` returns an Int exits with it, as it does alone.
        \\pub fn main(init: std.process.Init.Minimal) u8 {{
        \\    const argv = init.args.vector;
        \\    if (argv.len < 2) {{
        \\        std.debug.print("error: rig batch: name a program of this batch by its number\n", .{{}});
        \\        std.process.exit(2);
        \\    }}
        \\    const id = std.mem.span(argv[1]);
        \\    const n = std.fmt.parseInt(usize, id, 10) catch std.math.maxInt(usize);
        \\    const own = std.heap.page_allocator.alloc([*:0]const u8, argv.len - 1) catch std.process.exit(2);
        \\    own[0] = argv[0];
        \\    @memcpy(own[1..], argv[2..]);
        \\    var program_init = init;
        \\    program_init.args.vector = own;
        \\    inline for (programs) |p| {{
        \\        if (p[0] == n) {{
        \\            const status = p[1].main(program_init);
        \\            return if (@TypeOf(status) == void) 0 else status;
        \\        }}
        \\    }}
        \\    std.debug.print("error: rig batch: no program `{{s}}` in this batch\n", .{{id}});
        \\    std.process.exit(2);
        \\}}
        \\
    , .{});
    try writePackage(allocator, io, dir, &.{
        .{ .path = emit.runtime_filename, .contents = emit.runtime_source },
        .{ .path = emit.tasks_filename, .contents = emit.tasks_source },
        .{ .path = emit.sched_filename, .contents = emit.sched_source },
        .{ .path = "main.zig", .contents = root.written() },
        .{ .path = "programs", .contents = list.written() },
    });

    const bin = try std.fs.path.join(allocator, &.{ dir, "bin" });
    // A Zig that cannot say what it is (`zigIdentity`) builds every time.
    const zig_identity = zigIdentity(allocator, io, env);
    for ([_][]const u8{ emit.runtime_source, emit.tasks_source, emit.sched_source, root.written(), env.zig(), zig_identity orelse "", mode.zigFlag(), if (links_libc) "-lc" else "" }) |part| Part.add(&inputs, part);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    inputs.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const inputs_path = try std.fs.path.join(allocator, &.{ dir, "inputs" });
    const built_from = std.Io.Dir.cwd().readFileAlloc(io, inputs_path, allocator, .limited(hex.len + 1)) catch "";
    if (zig_identity != null and std.mem.eql(u8, built_from, &hex) and exists(io, dir, "bin")) return 0;
    std.Io.Dir.cwd().deleteFile(io, inputs_path) catch {};
    // A failed build leaves no executable, so `batch run` never runs an
    // older batch's.
    std.Io.Dir.cwd().deleteFile(io, bin) catch |err| switch (err) {
        error.FileNotFound => {},
        else => fatal("error: cannot remove `{s}`: {s}", .{ bin, @errorName(err) }),
    };
    const libc: []const []const u8 = if (links_libc) &.{"-lc"} else &.{};
    const argv = try std.mem.concat(allocator, []const u8, &.{
        &.{ env.zig(), "build-exe", mode.zigFlag(), "--cache-dir", try std.fs.path.join(allocator, &.{ dir, ".zig-cache" }), try allocator.print("-femit-bin={s}", .{bin}) },
        libc,
        &.{ "--dep", emit.runtime_module, try allocator.print("-Mroot={s}", .{try std.fs.path.join(allocator, &.{ dir, "main.zig" })}), try allocator.print("-M{s}={s}", .{ emit.runtime_module, try std.fs.path.join(allocator, &.{ dir, emit.runtime_filename }) }) },
    });
    const code = try runZig(io, argv);
    if (code == 0 and zig_identity != null) try writeFile(io, inputs_path, &hex);
    return code;
}

/// Where `rig build` keeps the executable it built, so that the same
/// build again copies it and does not run Zig:
/// `ZIG_CACHE/rig-build/MODE/HASH/NAME`, NAME the output's file name,
/// which Zig signs an executable with on macOS, and HASH a hash of every
/// file of the package, the Zig command but its output, NAME, and Zig
/// itself (`zigIdentity`). It is used while the object files its build
/// left are there (`keepBuild`, `reuseBuild`). Each mode keeps its last
/// build. Null when Zig cannot say what it is: then every build runs Zig.
fn keptBuild(allocator: std.mem.Allocator, io: std.Io, env: Env, zig_cache: []const u8, mode: Mode, out: []const u8, zig_args: []const []const u8, files: []const PackageFile) !?[]const u8 {
    const identity = zigIdentity(allocator, io, env) orelse return null;
    const name = std.fs.path.basename(out);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    const Part = struct {
        fn add(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
            var len: [8]u8 = undefined;
            std.mem.writeInt(u64, &len, bytes.len, .little);
            hash.update(&len);
            hash.update(bytes);
        }
    };
    Part.add(&h, "rig build kept 1");
    Part.add(&h, identity);
    for (zig_args) |arg| Part.add(&h, arg);
    Part.add(&h, name);
    for (files) |f| {
        Part.add(&h, f.path);
        Part.add(&h, f.contents);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    return try std.fs.path.join(allocator, &.{ zig_cache, "rig-build", @tagName(mode), &std.fmt.bytesToHex(digest[0..16], .lower), name });
}

/// Keep the executable a build wrote at `out` as `kept` (`keptBuild`),
/// in place of the mode's last one, with the list of the directories the
/// build left in the Zig cache's `tmp` (those not in `before`), in
/// `objects` beside it: on macOS an executable's debug information stays
/// in the object files there, which its stack traces read. A failure
/// only means the next build runs Zig.
fn keepBuild(allocator: std.mem.Allocator, io: std.Io, kept: []const u8, out: []const u8, zig_cache: []const u8, before: []const []const u8) void {
    const entry = std.fs.path.dirname(kept).?;
    const mode_dir = std.fs.path.dirname(entry).?;
    if (std.Io.Dir.cwd().openDir(io, mode_dir, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (!eql(e.name, std.fs.path.basename(entry))) dir.deleteTree(io, e.name) catch {};
        }
    } else |_| {}
    var objects: std.Io.Writer.Allocating = .init(allocator);
    new: for (zigObjects(allocator, io, zig_cache)) |name| {
        for (before) |old| if (eql(old, name)) continue :new;
        const path = std.fs.path.join(allocator, &.{ zig_cache, "tmp", name }) catch return;
        objects.writer.print("{s}\n", .{path}) catch return;
    }
    const list = std.fs.path.join(allocator, &.{ entry, "objects" }) catch return;
    var file = std.Io.Dir.cwd().createFileAtomic(io, list, .{ .make_path = true, .replace = true }) catch return;
    defer file.deinit(io);
    file.file.writeStreamingAll(io, objects.written()) catch return;
    file.replace(io) catch return;
    std.Io.Dir.cwd().copyFile(out, std.Io.Dir.cwd(), kept, io, .{}) catch {};
}

/// Copy the executable `rig build` kept (`keptBuild`) to `out`, replacing
/// it atomically, when it and every object directory its build left
/// (`keepBuild`) are still there: false if not.
fn reuseBuild(allocator: std.mem.Allocator, io: std.Io, kept: []const u8, out: []const u8) bool {
    const list = std.fs.path.join(allocator, &.{ std.fs.path.dirname(kept).?, "objects" }) catch return false;
    const objects = std.Io.Dir.cwd().readFileAlloc(io, list, allocator, .limited(1 << 20)) catch return false;
    var lines = std.mem.tokenizeScalar(u8, objects, '\n');
    while (lines.next()) |path| if (!isDirectory(io, path)) return false;
    std.Io.Dir.cwd().copyFile(kept, std.Io.Dir.cwd(), out, io, .{}) catch return false;
    return true;
}

/// The names in the Zig cache's `tmp`, where `zig build-exe` leaves the
/// object files of an executable it is told to write.
fn zigObjects(allocator: std.mem.Allocator, io: std.Io, zig_cache: []const u8) []const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const tmp = std.fs.path.join(allocator, &.{ zig_cache, "tmp" }) catch return &.{};
    var d = std.Io.Dir.cwd().openDir(io, tmp, .{ .iterate = true }) catch return &.{};
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        names.append(allocator, allocator.dupe(u8, e.name) catch return names.items) catch return names.items;
    }
    return names.items;
}

/// What Zig says of itself, for the hash of a build rig keeps: `zig env`
/// (its version, executable, and library, the native target with the
/// system's version, and the variables it reads), the size, time, and
/// inode of its executable, and the host's name, so another Zig, even
/// one of the same version, another system, or another machine sharing
/// the directory never reuses a build. Null when Zig does not say.
fn zigIdentity(allocator: std.mem.Allocator, io: std.Io, env: Env) ?[]const u8 {
    const r = std.process.run(allocator, io, .{
        .argv = &.{ env.zig(), "env" },
        .stdout_limit = .limited(1 << 16),
        .stderr_limit = .limited(1 << 16),
    }) catch return null;
    if (!r.term.success()) return null;
    if (std.mem.indexOf(u8, r.stdout, ".version = \"") == null) return null;
    var id: std.Io.Writer.Allocating = .init(allocator);
    id.writer.writeAll(r.stdout) catch return null;
    const exe = ".zig_exe = \"";
    const at = std.mem.indexOf(u8, r.stdout, exe) orelse return null;
    const path = r.stdout[at + exe.len ..];
    const st = std.Io.Dir.cwd().statFile(io, path[0 .. std.mem.indexOfScalar(u8, path, '"') orelse return null], .{}) catch return null;
    id.writer.print("{d} {d} {d}\n", .{ st.size, st.mtime.nanoseconds, st.inode }) catch return null;
    if (builtin.os.tag != .windows) {
        const uts = std.posix.uname();
        id.writer.print("{s}\n", .{std.mem.sliceTo(&uts.nodename, 0)}) catch return null;
    }
    return id.written();
}

/// `rig batch run DIR N` (`batchCommand`).
fn batchRun(allocator: std.mem.Allocator, io: std.Io, env: Env, dir: []const u8, id: []const u8) !u8 {
    _ = std.fmt.parseInt(usize, id, 10) catch usageError("`{s}` is not a program's number", .{id});
    if (env.get(run_started_var)) |path| {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => notRun("cannot clear RIG_RUN_STARTED `{s}`: {s}", .{ path, @errorName(err) }),
        };
    }
    program_pending = true;
    const bin = try std.fs.path.join(allocator, &.{ dir, "bin" });
    _ = std.Io.Dir.cwd().statFile(io, bin, .{}) catch notRun("no batch executable `{s}`: run `rig batch build` first", .{bin});
    var environ = try env.map.clone(allocator);
    _ = environ.swapRemove(run_started_var);
    const started_dir = try std.fs.path.join(allocator, &.{ dir, ".started" });
    std.Io.Dir.cwd().createDirPath(io, started_dir) catch |err| notRun("cannot create `{s}`: {s}", .{ started_dir, @errorName(err) });
    var name: [8]u8 = undefined;
    io.random(&name);
    const started = try std.fs.path.join(allocator, &.{ started_dir, try allocator.print(".started-{x}", .{&name}) });
    try environ.put(program_started_var, started);
    const ended = try runZigReport(io, &.{ bin, id }, &environ);
    const ran = if (std.Io.Dir.cwd().statFile(io, started, .{})) |st| st.kind == .file else |_| false;
    std.Io.Dir.cwd().deleteFile(io, started) catch {};
    if (!ran) notRun("program {s} of `{s}` exited with status {d}, and left no sign that it started", .{ id, bin, ended.code });
    if (env.get(run_started_var)) |path| try writeFile(io, path, "");
    if (ended.signal) |sig| std.debug.print("error: rig: the program was killed by signal {d}\n", .{sig});
    return ended.code;
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

fn isDirectory(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

fn exists(io: std.Io, dir: []const u8, name: []const u8) bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ dir, name }) catch return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// The module `rig test` builds: a driver next to the emitted ones that
/// runs the `__rig_tests` table of the root module only (see
/// `rig.runTests`); an imported module's tests are not emitted.
const test_driver = "__rig_test.zig";

fn testDriver(allocator: std.mem.Allocator, env: Env, graph: *modules.ModuleGraph) ![]const u8 {
    var driver: std.Io.Writer.Allocating = .init(allocator);
    const w = &driver.writer;
    try w.print(
        \\const rig = @import("{s}");
        \\
        \\pub const panic = rig.panic;
        \\
    , .{emit.runtime_filename});
    try env.writeRootFlags(w, true, taskGuardOf(graph));
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
    try w.print("        .{{ .module = \"\", .tests = testsOf(@import(\"{s}\")) }},\n", .{graph.root().out_basename});
    try w.writeAll("    });\n}\n");
    return driver.written();
}

/// Run the Zig toolchain with inherited stdio; return its exit code (128 +
/// the signal number if a signal ended it).
fn runZig(io: std.Io, argv: []const []const u8) !u8 {
    return (try runZigReport(io, argv, null)).code;
}

const Ended = struct { code: u8, signal: ?u8 = null };

/// A request to end this process (SIGTERM or SIGHUP), as a test runner's
/// time limit sends one, passes on to the process `runZigReport` runs,
/// which would otherwise run on with no parent, and this process then
/// ends as the child does. One that comes before the child has started
/// reaches it as it starts.
const Ending = struct {
    const signals = [_]std.posix.SIG{ .TERM, .HUP };
    var child: std.atomic.Value(std.posix.pid_t) = .init(0);
    var pending: std.atomic.Value(u32) = .init(0);

    fn watch() void {
        if (std.posix.Sigaction == void) return;
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = passOn },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        for (signals) |sig| std.posix.sigaction(sig, &act, null);
    }

    fn started(pid: std.posix.pid_t) void {
        child.store(pid, .seq_cst);
        const sig = pending.swap(0, .seq_cst);
        if (sig != 0) std.posix.kill(pid, @enumFromInt(sig)) catch {};
    }

    fn passOn(sig: std.posix.SIG) callconv(.c) void {
        if (child.load(.seq_cst) == 0) {
            pending.store(@intCast(@intFromEnum(sig)), .seq_cst);
            // The child started meanwhile, and `started` may have missed
            // the signal: whichever of the two takes it passes it on.
            const pid = child.load(.seq_cst);
            if (pid == 0 or pending.swap(0, .seq_cst) == 0) return;
            std.posix.kill(pid, sig) catch {};
            return;
        }
        std.posix.kill(child.load(.seq_cst), sig) catch {};
    }
};

/// Run the Zig toolchain with inherited stdio (and `environ`, when given,
/// as its environment); return its exit code and the signal that ended
/// it, if one did. For `zig run` (`environ` given) these are the
/// program's once it has started: Zig replaces itself with it.
fn runZigReport(io: std.Io, argv: []const []const u8, environ: ?*const std.process.Environ.Map) !Ended {
    // `zig run` for `rig run` and `rig test`: on macOS this process answers the child's crashes as
    // handled, so neither the user's nor the system's ReportCrash files one; a panic's message and
    // trace are on stderr already. Clearing the program's own handler would stop only the user's.
    // The child is compile and program in one process: a compiler crash in such a run files no
    // report either, though it still fails the run.
    var catcher: ?CrashCatcher = null;
    if (builtin.os.tag.isDarwin() and environ != null) catcher = CrashCatcher.start();
    Ending.watch();
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
    // This process's own handlers back: its own crashes are reported as ever.
    if (catcher) |*k| k.restore();
    if (child.id) |pid| Ending.started(pid);
    return switch (try child.wait(io)) {
        .exited => |code| .{ .code = code },
        .signal => |sig| .{ .code = 128 +| @as(u8, @truncate(@backingInt(sig))), .signal = @truncate(@backingInt(sig)) },
        else => .{ .code = 1 },
    };
}

extern "c" var mach_task_self_: c_uint;
extern "c" fn mach_port_allocate(task: c_uint, right: c_uint, name: *c_uint) c_int;
extern "c" fn mach_port_insert_right(task: c_uint, name: c_uint, poly: c_uint, poly_type: c_uint) c_int;
extern "c" fn task_get_exception_ports(task: c_uint, mask: c_uint, masks: [*]c_uint, count: *c_uint, ports: [*]c_uint, behaviors: [*]c_int, flavors: [*]c_int) c_int;
extern "c" fn task_set_exception_ports(task: c_uint, mask: c_uint, port: c_uint, behavior: c_int, flavor: c_int) c_int;
extern "c" fn mach_msg(msg: *anyopaque, option: c_int, send_size: c_uint, rcv_size: c_uint, rcv_name: c_uint, timeout: c_uint, notify: c_uint) c_int;
extern "c" var NDR_record: [8]u8;

/// macOS: answers the crashes of the processes this one starts as handled, so no crash report is
/// filed for them, by the user's ReportCrash or the system's. Their crash exceptions (EXC_CRASH,
/// EXC_CORPSE_NOTIFY) come to a port of this process's, which they inherit across spawn and exec,
/// and a thread replies to each. `restore` puts this process's own handlers back once the child
/// is started. As cpuq's `cpuq cap --no-crash-report` does (its src/sys.zig).
const CrashCatcher = struct {
    const mask: c_uint = (1 << 10) | (1 << 13);
    const max = 32;
    port: c_uint = 0,
    count: c_uint = max,
    masks: [max]c_uint = undefined,
    ports: [max]c_uint = undefined,
    behaviors: [max]c_int = undefined,
    flavors: [max]c_int = undefined,

    fn start() ?CrashCatcher {
        if (!builtin.os.tag.isDarwin()) return null;
        var k: CrashCatcher = .{};
        if (mach_port_allocate(mach_task_self_, 1, &k.port) != 0) return null; // MACH_PORT_RIGHT_RECEIVE
        if (mach_port_insert_right(mach_task_self_, k.port, k.port, 20) != 0) return null; // MACH_MSG_TYPE_MAKE_SEND
        if (task_get_exception_ports(mach_task_self_, mask, &k.masks, &k.count, &k.ports, &k.behaviors, &k.flavors) != 0) return null;
        const thread_state_none: c_int = if (builtin.cpu.arch == .x86_64) 13 else 5;
        if (task_set_exception_ports(mach_task_self_, mask, k.port, 1, thread_state_none) != 0) return null; // EXCEPTION_DEFAULT
        const t = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, serve, .{k.port}) catch {
            k.restore();
            return null;
        };
        t.detach();
        return k;
    }

    fn restore(k: *const CrashCatcher) void {
        if (!builtin.os.tag.isDarwin()) return;
        for (0..k.count) |i| _ = task_set_exception_ports(mach_task_self_, k.masks[i], k.ports[i], k.behaviors[i], k.flavors[i]);
    }

    fn serve(port: c_uint) void {
        // mach_msg_header_t: bits, size, remote port, local port, voucher port, id.
        const Header = extern struct { bits: u32, size: u32, remote: u32, local: u32, voucher: u32, id: i32 };
        const Reply = extern struct { h: Header, ndr: [8]u8, ret: i32 };
        var req: [4096]u8 align(8) = undefined;
        while (true) {
            const h: *Header = @ptrCast(&req);
            if (mach_msg(&req, 2, 0, req.len, port, 0, 0) != 0) continue; // MACH_RCV_MSG
            // exception_raise's reply: handled (KERN_SUCCESS), so no one else is told.
            var rep: Reply = .{
                .h = .{ .bits = h.bits & 0x1f, .size = @sizeOf(Reply), .remote = h.remote, .local = 0, .voucher = 0, .id = h.id + 100 },
                .ndr = NDR_record,
                .ret = 0,
            };
            _ = mach_msg(&rep, 1, @sizeOf(Reply), 0, 0, 0, 0); // MACH_SEND_MSG
        }
    }
};

fn declaresMain(m: *const modules.Module) bool {
    if (m.ir == .nil) return false;
    for (ir.Module.decls(m.ir)) |top| {
        const decl = if (top.isKind(.@"pub")) ir.Pub.decl(top) else top;
        if (!decl.isKind(.sub) and !decl.isKind(.fun)) continue;
        if (std.mem.eql(u8, rig.leafText(m.source, ir.get(decl, .name).src), "main")) return true;
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

/// Module `m`'s files, each by its path from the package root: the
/// directory of the root module, which the program's own modules are
/// found under.
fn packageFile(allocator: std.mem.Allocator, graph: *const modules.ModuleGraph, m: *const modules.Module) !diag.File {
    const parts = try allocator.alloc(diag.Part, m.parts.len);
    for (m.parts, parts) |p, *out| out.* = .{ .start = p.start, .path = fromPackageRoot(graph, p.path) };
    return .{ .source = m.source, .path = fromPackageRoot(graph, m.display), .parts = parts };
}

/// `path` from the package root (`packageFile`), or as it is when it is
/// outside it.
fn fromPackageRoot(graph: *const modules.ModuleGraph, path: []const u8) []const u8 {
    const root = graph.import_dir orelse return path;
    if (root.len == 0 or std.mem.eql(u8, root, ".")) return path;
    if (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/') return path[root.len + 1 ..];
    return path;
}

/// Some module of the program makes a task (`f(x)&`).
/// The most stack any large frame of the program may take
/// (`SemContext.large_frames`), or 0 when it has none.
fn largestFrame(graph: *const modules.ModuleGraph) u64 {
    var most: u64 = 0;
    for (graph.modules.items) |*m| {
        var it = m.sema.large_frames.valueIterator();
        while (it.next()) |b| most = @max(most, b.*);
    }
    return most;
}

/// The guard below each task's stack (`sema.taskGuard`), for a program
/// that makes tasks; null for one that makes none.
fn taskGuardOf(graph: *const modules.ModuleGraph) ?u64 {
    if (!makesTasks(graph)) return null;
    return sema.taskGuard(largestFrame(graph));
}

fn makesTasks(graph: *const modules.ModuleGraph) bool {
    for (graph.modules.items) |*m| if (m.sema.makes_tasks) return true;
    return false;
}

/// How `emitPackage` writes a package.
const PackageKind = struct {
    /// `rig run`: the root module names the file the program creates as
    /// it starts.
    hook: bool = false,
    /// `rig batch`: the modules import the runtime as the module the
    /// batch shares, which the package leaves out, and the batch's root
    /// declares the runtime's settings.
    batch: bool = false,
};

/// Emit the runtime and every module. With `RIG_LEAK_TRACE` or
/// `RIG_SANITIZE` set, the root module asks the runtime for stack-trace
/// leak reports or the sanitizer; with `RIG_SANITIZE`, emit also poisons
/// hidden storage when its scope ends.
fn emitPackage(allocator: std.mem.Allocator, env: Env, graph: *modules.ModuleGraph, kind: PackageKind) !Package {
    const hook = kind.hook;
    const runtime_import = if (kind.batch) emit.runtime_module else emit.runtime_filename;
    var files: std.ArrayList(PackageFile) = .empty;
    if (!kind.batch) {
        try files.append(allocator, .{ .path = emit.runtime_filename, .contents = emit.runtime_source });
        try files.append(allocator, .{ .path = emit.tasks_filename, .contents = emit.tasks_source });
        try files.append(allocator, .{ .path = emit.sched_filename, .contents = emit.sched_source });
    }

    var root_source: []const u8 = "";
    var links_libc = false;
    var uses_symbols = false;
    const tasks = makesTasks(graph);
    const task_guard = taskGuardOf(graph);
    for (graph.modules.items, 0..) |*m, i| {
        var file_buffer: std.Io.Writer.Allocating = .init(allocator);
        var em = emit.Emitter.init(allocator, m.source, &file_buffer.writer, emit_facts.Facts.of(m.sema));
        defer em.deinit();
        em.poison = env.sanitize();
        em.no_proofs = env.flag("RIG_NO_PROOFS");
        em.strict_optionals = env.flag("RIG_STRICT_OPTIONALS");
        em.yield_checks = tasks;
        em.runtime_import = runtime_import;
        em.file = try packageFile(allocator, graph, m);
        // A debug build of the compiler checks that emit writes the units
        // the proof pass walks, in the same order (`proofs.checkUnitOrder`).
        var trace: std.ArrayList(emit.UnitEvent) = .empty;
        defer trace.deinit(allocator);
        if (emit_facts.check_units) em.unit_trace = &trace;
        try em.emit(m.ir);
        if (emit_facts.check_units) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            if (try proofs.checkUnitOrder(m.sema, arena.allocator(), m.ir, trace.items)) |what| {
                std.debug.print("{s}: internal error: emit writes units other than the proof pass walks: {s}\n", .{ m.display, what });
                return error.Unsupported;
            }
        }
        links_libc = links_libc or em.links_libc;
        uses_symbols = uses_symbols or em.uses_symbols;
        if (i == 0 and !kind.batch and (env.leakTrace() or env.sanitize() or env.verifyProofs() or hook or tasks)) {
            try file_buffer.writer.writeAll("\n");
            try env.writeRootFlags(&file_buffer.writer, hook, task_guard);
        }
        try files.append(allocator, .{ .path = m.out_basename, .contents = file_buffer.written() });
        for (m.shims.items) |shim| {
            // A shim beside the runtime imports it by its path; in a batch
            // it imports the module the batch shares.
            const contents = if (kind.batch) try std.mem.replaceOwned(u8, allocator, shim.source, "@import(\"../runtime.zig\")", "@import(\"" ++ emit.runtime_module ++ "\")") else shim.source;
            try files.append(allocator, .{ .path = try std.fs.path.join(allocator, &.{ "rig", "std", shim.name }), .contents = contents });
        }
        if (i == 0) root_source = file_buffer.written();
    }
    // Every symbol of every module, numbered once (`src/symbols.zig`).
    if (uses_symbols) {
        const sources = try allocator.alloc(symbols.Source, graph.modules.items.len);
        for (graph.modules.items, sources) |*m, *s| s.* = .{ .source = m.source, .ir = m.ir };
        var out: std.Io.Writer.Allocating = .init(allocator);
        try symbols.write(allocator, &out.writer, try symbols.collect(allocator, sources), runtime_import);
        try files.append(allocator, .{ .path = emit.symbols_filename, .contents = out.written() });
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

/// The most the cache home holds, in gigabytes, unless `RIG_CACHE_MAX_GB`
/// says another (0 for no limit), and how soon a cache over it is
/// trimmed again.
const cache_default_max_gb = 10;
const cache_over_trim_minutes = 10;

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

/// The file in each package holding its size in bytes (the files under
/// it but this one), as the build that last ran there measured it
/// (`recordSize`), and the file in the cache home holding the estimate of
/// every package's size added up. The estimate is what a run reads to
/// learn whether the cache is over its limit; a trim measures it anew.
const package_size = ".size";
const cache_usage = ".usage";

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
    /// The file `.usage`, the estimate of the cache's size.
    usage,

    /// The kind of the entry `name` of `dir`, or null for anything rig
    /// did not make, a symbolic link included.
    fn of(dir: std.Io.Dir, io: std.Io, name: []const u8, kind: std.Io.File.Kind) ?CacheEntry {
        if (kind == .file and eql(name, ".trimmed")) {
            const st = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return null;
            return if (st.kind == .file and st.size == 0) .stamp else null;
        }
        if (kind == .file and eql(name, cache_usage)) {
            const st = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return null;
            return if (st.kind == .file and st.size <= 32) .usage else null;
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
/// it holds rig's packages or stamp and nothing else (a home an earlier
/// rig made before it wrote tags). A home with anything else in it, or that is a
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
    // Proof that rig made it: at least one package or rig's stamp, and
    // nothing else. Trash, known by its name alone, and an empty
    // directory prove nothing.
    var proof = false;
    var it = d.iterate();
    while (it.next(io) catch return) |entry| switch (CacheEntry.of(d, io, entry.name, entry.kind) orelse return) {
        .package, .stamp, .usage => proof = true,
        .trash, .tag => return,
    };
    if (proof) writeTag(io, home);
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
        cwd.createDirPath(io, dir) catch continue;
        const f = openLock(io, cwd, path) orelse continue;
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

/// The lock file at `path` of `dir`, opened to read and write (Linux NFS
/// takes a lock only in the mode a file is open for), made if missing,
/// and never through a link. Null if it cannot be opened.
fn openLock(io: std.Io, dir: std.Io.Dir, path: []const u8) ?std.Io.File {
    for (0..2) |_| {
        if (dir.openFile(io, path, .{ .mode = .read_write, .follow_symlinks = false })) |f| return f else |err| if (err != error.FileNotFound) return null;
        if (dir.createFile(io, path, .{ .read = true, .exclusive = true })) |f| return f else |err| if (err != error.PathAlreadyExists) return null;
    }
    return null;
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
    if (pd.createFile(io, package_lock, .{ .read = true, .exclusive = true })) |f| {
        f.close(io);
        created.* = true;
    } else |_| {}
    const f = openLock(io, pd, package_lock) orelse return null;
    const locked = f.tryLock(io, .exclusive) catch |err| {
        f.close(io);
        return if (err == error.FileLocksUnsupported) error.FileLocksUnsupported else null;
    };
    // Still the package at `name`, not one a run made there after
    // another trim renamed this one away.
    const held = f.stat(io) catch null;
    var lock_path: [std.fs.max_path_bytes]u8 = undefined;
    const at = std.fmt.bufPrint(&lock_path, "{s}/{s}", .{ name, package_lock }) catch null;
    const now = if (at) |path| dir.statFile(io, path, .{ .follow_symlinks = false }) catch null else null;
    if (!locked or held == null or now == null or held.?.inode != now.?.inode) {
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

/// What a package must still be, read again under its lock, to be
/// removed: anything (`rig clean`), unused for `cache_keep_days`, or
/// last used at the time the trim saw (not used since).
const Check = union(enum) { none, aged, unchanged: ?std.Io.Timestamp };

/// Remove `name` of `dir`. A package is locked exclusively first (a
/// package in use is `busy`), checked again, with `aged`, to be unused
/// by its time read under the lock (or, where taking the lock made its
/// lock file, the time before) as `check` says, and renamed out of the way in one step
/// under the lock, so a run never meets one half removed; then deleted.
/// `gone` when another process removed it first.
fn removeEntry(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, kind: CacheEntry, check: Check) Removal {
    switch (kind) {
        .stamp, .tag, .usage => {
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
            const seen = if (created) before else lastUsed(dir, io, name);
            const fits = switch (check) {
                .none => true,
                .aged => unusedSince(io, seen),
                .unchanged => |t| t != null and seen != null and t.?.nanoseconds == seen.?.nanoseconds,
            };
            if (!fits) {
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

/// The limit on the cache home's size in bytes: `RIG_CACHE_MAX_GB`
/// gigabytes (a decimal number), `cache_default_max_gb` when it is unset
/// or not one. Zero is no limit.
fn cacheCap(env: Env) u64 {
    const gib: f64 = 1024 * 1024 * 1024;
    const gb: f64 = if (env.get("RIG_CACHE_MAX_GB")) |text| std.fmt.parseFloat(f64, text) catch cache_default_max_gb else cache_default_max_gb;
    if (!(gb >= 0) or gb > 1e9) return cache_default_max_gb * @as(u64, gib);
    return @intFromFloat(gb * gib);
}

/// The sum of the sizes of the regular files under `dir`, links not
/// followed, apart from a `.size` directly in it.
fn treeSize(io: std.Io, dir: std.Io.Dir, top: bool, depth: u32) u64 {
    if (depth > 64) return 0;
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch return total) |entry| switch (entry.kind) {
        .file => {
            if (top and eql(entry.name, package_size)) continue;
            const st = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
            if (st.kind == .file) total +|= st.size;
        },
        .directory => {
            var sub = dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
            defer sub.close(io);
            total +|= treeSize(io, sub, false, depth + 1);
        },
        else => {},
    };
    return total;
}

/// The size of the package `name` of `dir`, measured.
fn measurePackage(io: std.Io, dir: std.Io.Dir, name: []const u8) u64 {
    var pd = dir.openDir(io, name, .{ .iterate = true, .follow_symlinks = false }) catch return 0;
    defer pd.close(io);
    return treeSize(io, pd, true, 0);
}

/// The largest size rig believes in, a petabyte; a recorded size above it
/// is corrupt.
const size_bound: u64 = 1 << 50;

/// The number in the small file `path` of `dir`, as rig writes it: decimal
/// digits and a newline, at most `size_bound`. Null if the file is
/// missing, a link, or holds anything else (as when it is being replaced).
fn readNumber(io: std.Io, dir: std.Io.Dir, path: []const u8) ?u64 {
    const f = dir.openFile(io, path, .{ .follow_symlinks = false }) catch return null;
    defer f.close(io);
    var buffer: [32]u8 = undefined;
    const n = f.readPositionalAll(io, &buffer, 0) catch return null;
    var text = buffer[0..n];
    if (text.len < 2 or text[text.len - 1] != '\n') return null;
    text = text[0 .. text.len - 1];
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    const value = std.fmt.parseInt(u64, text, 10) catch return null;
    return if (value > size_bound) null else value;
}

/// Whether the home's `.usage` is absent or rig's own, so rig may write
/// it; a file or link rig did not make is never replaced.
fn usageWritable(io: std.Io, dir: std.Io.Dir) bool {
    const st = dir.statFile(io, cache_usage, .{ .follow_symlinks = false }) catch |err| return err == error.FileNotFound;
    return st.kind == .file and readNumber(io, dir, cache_usage) != null;
}

fn writeNumber(io: std.Io, path: []const u8, value: u64) void {
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}\n", .{value}) catch return;
    var file = std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true }) catch return;
    defer file.deinit(io);
    file.file.writeStreamingAll(io, text) catch return;
    file.replace(io) catch {};
}

/// Record the size of the package `dir` of the cache home `home` in its
/// `.size`, and move the home's `.usage` estimate by the change. Without
/// a `.usage` (no trim has measured the cache yet) only the package's
/// size is recorded. It walks one package, never the cache.
fn recordSize(allocator: std.mem.Allocator, io: std.Io, home: []const u8, dir: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    {
        // Only in a home rig made.
        var hd = cwd.openDir(io, home, .{ .follow_symlinks = false }) catch return;
        defer hd.close(io);
        if (!isTag(hd, io)) return;
    }
    var pd = cwd.openDir(io, dir, .{ .iterate = true, .follow_symlinks = false }) catch return;
    defer pd.close(io);
    const size = treeSize(io, pd, true, 0);
    const old = readNumber(io, pd, package_size);
    if (old != null and old.? == size) return;
    const size_path = std.fs.path.join(allocator, &.{ dir, package_size }) catch return;
    writeNumber(io, size_path, size);
    const usage_path = std.fs.path.join(allocator, &.{ home, cache_usage }) catch return;
    const estimate = readNumber(io, cwd, usage_path) orelse return;
    writeNumber(io, usage_path, (estimate -| (old orelse 0)) +| size);
}

/// Remove the packages in the cache home `home` that no run or build has
/// used for `cache_keep_days`, all but `current` and any a run, build,
/// or test holds (`holdPackage`), and what an interrupted trim left.
/// Then, if the packages left are over `cap` bytes (0 for no limit), it
/// removes the least recently used ones, by the time a run last set on
/// them, until the rest fit. It acts only on a home rig made
/// (`openCacheHome`). A stamp, `.trimmed`, records the last trim, so
/// this reads the directory at most once in `cache_trim_days`, or once in
/// `cache_over_trim_minutes` while the estimate in `.usage` (or its
/// absence) says the cache is over `cap`; a stamp dated in the future
/// counts as old. Each package's time is checked again, under its lock,
/// just before it goes. A trim measures every package it keeps and
/// writes the total as the new estimate. One line on stderr says how many
/// went, and why. Where the system has no file locks, nothing is
/// removed. A failure never fails the build.
fn trimCache(allocator: std.mem.Allocator, io: std.Io, home: []const u8, current: []const u8, cap: u64) void {
    var why: []const u8 = "";
    var d = openCacheHome(io, home, &why) orelse return;
    defer d.close(io);
    const now = std.Io.Timestamp.now(io, .real);
    const estimate = if (cap > 0) readNumber(io, d, cache_usage) else null;
    // A `.usage` that is not rig's is neither read nor replaced: the cache
    // is then measured at the daily pace.
    const writable = usageWritable(io, d);
    const over = cap > 0 and writable and (estimate == null or estimate.? > cap);
    const wait: i96 = if (over) cache_over_trim_minutes * std.time.ns_per_min else cache_trim_days * std.time.ns_per_day;
    if (d.statFile(io, ".trimmed", .{ .follow_symlinks = false })) |st| {
        if (st.kind != .file or st.size != 0) return;
        const age = st.mtime.durationTo(now).nanoseconds;
        if (age >= 0 and age < wait) return;
        d.setTimestampsNow(io, ".trimmed", .{ .follow_symlinks = false }) catch return;
    } else |_| {
        const file = d.createFile(io, ".trimmed", .{ .exclusive = true }) catch return;
        file.close(io);
    }
    const Item = struct { name: []const u8, kind: CacheEntry, used: ?std.Io.Timestamp = null, size: u64 = 0 };
    var old: std.ArrayList(Item) = .empty;
    var live: std.ArrayList(Item) = .empty;
    var total: u64 = 0;
    var it = d.iterate();
    while (it.next(io) catch return) |entry| {
        const kind = CacheEntry.of(d, io, entry.name, entry.kind) orelse continue;
        if (kind == .stamp or kind == .tag or kind == .usage) continue;
        var item: Item = .{ .name = allocator.dupe(u8, entry.name) catch return, .kind = kind };
        if (kind == .package) {
            item.used = lastUsed(d, io, entry.name);
            if (cap > 0) {
                const recorded = readNumber(io, d, std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.name, package_size }) catch return);
                // The package in use is measured when its build ends
                // (`recordSize`), which adds its whole size if it has
                // none recorded.
                item.size = recorded orelse if (eql(entry.name, current)) 0 else measurePackage(io, d, entry.name);
                total +|= item.size;
            }
            if (eql(entry.name, current) or !unusedSince(io, item.used)) {
                live.append(allocator, item) catch return;
                continue;
            }
        }
        old.append(allocator, item) catch return;
    }
    var aged: usize = 0;
    for (old.items) |e| switch (removeEntry(allocator, io, d, e.name, e.kind, .aged)) {
        .removed, .gone => if (e.kind == .package) {
            aged += 1;
            total -|= e.size;
        },
        .unsupported => break,
        else => {},
    };
    if (aged > 0) std.debug.print("rig: removed {d} package{s} unused for {d} days from {s}\n", .{ aged, if (aged == 1) "" else "s", cache_keep_days, home });
    var capped: usize = 0;
    if (cap > 0 and total > cap) {
        std.mem.sort(Item, live.items, {}, struct {
            fn before(_: void, a: Item, b: Item) bool {
                const x = if (a.used) |t| t.nanoseconds else std.math.maxInt(i96);
                const y = if (b.used) |t| t.nanoseconds else std.math.maxInt(i96);
                return x < y;
            }
        }.before);
        for (live.items) |e| {
            if (total <= cap) break;
            if (eql(e.name, current)) continue;
            switch (removeEntry(allocator, io, d, e.name, .package, .{ .unchanged = e.used })) {
                .removed, .gone => {
                    capped += 1;
                    total -|= e.size;
                },
                .unsupported => break,
                else => {},
            }
        }
    }
    if (capped > 0) std.debug.print("rig: removed {d} least recently used package{s} to keep {s} under {d:.2} GB (RIG_CACHE_MAX_GB)\n", .{ capped, if (capped == 1) "" else "s", home, @as(f64, @floatFromInt(cap)) / (1024 * 1024 * 1024) });
    if (cap > 0 and writable) {
        const path = std.fs.path.join(allocator, &.{ home, cache_usage }) catch return;
        writeNumber(io, path, total);
    }
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
        if (kind == .stamp or kind == .tag or kind == .usage) continue;
        found.append(allocator, .{ .name = allocator.dupe(u8, entry.name) catch fatal("error: out of memory", .{}), .kind = kind }) catch fatal("error: out of memory", .{});
    }
    var removed: usize = 0;
    var busy: usize = 0;
    var kept = false;
    for (found.items) |e| switch (removeEntry(allocator, io, d, e.name, e.kind, .none)) {
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
    _ = removeEntry(allocator, io, d, ".trimmed", .stamp, .none);
    _ = removeEntry(allocator, io, d, cache_usage, .usage, .none);
    _ = removeEntry(allocator, io, d, cache_tag_name, .tag, .none);
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
    _ = proofs;
    _ = lsp;
    _ = @import("ownership.zig");
    _ = @import("runtime.zig");
    _ = @import("nametable.zig");
    _ = @import("symbols.zig");
}
