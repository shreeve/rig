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

const Mode = enum {
    parse,
    tokens,
    normalize,
    check,
    build,
    run,
    help,
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
        .build => try buildAndEmit(allocator, io, source, file_path),
        .run => try buildAndRun(allocator, io, source, file_path),
        .help => unreachable,
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

fn buildAndEmit(allocator: std.mem.Allocator, io: std.Io, source: []const u8, file_path: []const u8) !void {
    var checked = try parseAndCheckOrExit(allocator, io, source, file_path);
    defer checked.sema.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const w: *std.Io.Writer = &stdout_writer.interface;

    var em = emit.Emitter.initWithSema(allocator, source, w, &checked.sema);
    defer em.deinit();
    try em.emit(checked.ir);
    try w.flush();
}

fn buildAndRun(allocator: std.mem.Allocator, io: std.Io, source: []const u8, file_path: []const u8) !void {
    // Parse → check → emit Zig to a temp file → spawn `zig run <tmp>`.
    var checked = try parseAndCheckOrExit(allocator, io, source, file_path);
    defer checked.sema.deinit();

    var tmp_buf: [256]u8 = undefined;
    const tmp_path = makeTmpPath(&tmp_buf, file_path);

    {
        const f = std.Io.Dir.cwd().createFile(io, tmp_path, .{}) catch |err| {
            std.debug.print("error creating {s}: {}\n", .{ tmp_path, err });
            std.process.exit(1);
        };
        defer f.close(io);

        var file_buffer: [4096]u8 = undefined;
        var file_writer = f.writer(io, &file_buffer);
        const w: *std.Io.Writer = &file_writer.interface;

        var em = emit.Emitter.initWithSema(allocator, source, w, &checked.sema);
        defer em.deinit();
        try em.emit(checked.ir);
        try w.flush();
    }

    const argv = [_][]const u8{ "zig", "run", tmp_path };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("note: generated Zig at {s}\n", .{tmp_path});
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
