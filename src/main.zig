//! Rig compiler CLI.
//!
//!   rig tokens    <file.rig>  dump the token stream
//!   rig parse     <file.rig>  print the parse tree (grammar output)
//!   rig normalize <file.rig>  print the semantic IR
//!   rig check     <file.rig>  check the program and its imports
//!   rig build     <file.rig>  check, then emit Zig
//!   rig run       <file.rig>  check, emit, and run with `zig run`
//!
//! `build` and `run` never emit a program the checker rejects.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const emit = @import("emit.zig");
const modules = @import("modules.zig");
const runtime = @import("runtime.zig");

const usage =
    \\Rig — a systems language with visible ownership, compiled to Zig.
    \\
    \\Usage: rig <command> <file.rig>
    \\
    \\Commands:
    \\  tokens     Dump the token stream
    \\  parse      Print the parse tree
    \\  normalize  Print the semantic IR
    \\  check      Check the program and its imports
    \\  build      Check, then emit Zig (a single file to stdout; a
    \\             multi-module project to the output directory, whose
    \\             root file is printed)
    \\  run        Check, emit, and run with `zig run`
    \\
    \\Emitted Zig goes to $RIG_OUT_DIR when set, otherwise to a per-project
    \\directory under $XDG_CACHE_HOME/rig (default ~/.cache/rig).
    \\
;

const Command = enum { tokens, parse, normalize, check, build, run };

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len >= 2 and (std.mem.eql(u8, args[1], "-h") or
        std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "help")))
    {
        std.debug.print("{s}", .{usage});
        return;
    }
    if (args.len != 3) fatal("{s}", .{usage});

    const command = std.meta.stringToEnum(Command, args[1]) orelse
        fatal("unknown command `{s}`\n\n{s}", .{ args[1], usage });
    const path = args[2];

    switch (command) {
        .tokens, .parse, .normalize => {
            const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(modules.max_source_bytes)) catch |err|
                fatal("error: cannot read `{s}`: {s}", .{ path, @errorName(err) });
            switch (command) {
                .tokens => dumpTokens(source),
                .parse => try printTree(allocator, io, path, source, .raw),
                .normalize => try printTree(allocator, io, path, source, .semantic),
                else => unreachable,
            }
        },
        .check => {
            var graph = try loadProject(allocator, io, path);
            defer graph.deinit();
        },
        .build => try build(allocator, io, init.environ_map, path),
        .run => try run(allocator, io, init.environ_map, path),
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

fn dumpTokens(source: []const u8) void {
    var lexer = rig.Lexer.init(source);
    var i: u32 = 0;
    while (true) : (i += 1) {
        const tok = lexer.next();
        const lc = rig.lineCol(source, tok.pos);
        std.debug.print("{d:4} {d}:{d} {s:15} \"{s}\"\n", .{ i, lc.line, lc.col, @tagName(tok.cat), lexer.text(tok) });
        if (tok.cat == .eof or tok.cat == .err) break;
    }
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
            const d = p.diagnostic();
            const lc = rig.lineCol(source, d.pos);
            fatal("{s}:{d}:{d}: error: {s}", .{ path, lc.line, lc.col, d.message });
        },
        else => return err,
    };

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try tree.write(source, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

/// Load and check the project rooted at `path`; print every diagnostic
/// and exit 1 if there are errors.
fn loadProject(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !modules.ModuleGraph {
    var graph = modules.ModuleGraph.init(allocator, io);
    errdefer graph.deinit();
    try graph.loadRoot(path);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try graph.writeAllDiagnostics(&writer.interface);
    try writer.interface.flush();
    if (graph.hasErrors()) std.process.exit(1);
    return graph;
}

fn build(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, path: []const u8) !void {
    var graph = try loadProject(allocator, io, path);
    defer graph.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    const w = &writer.interface;

    const root = graph.root();
    if (root.imports.items.len == 0) {
        var em = emit.Emitter.initWithSema(allocator, root.source, w, root.sema);
        defer em.deinit();
        try em.emit(root.ir);
    } else {
        const root_zig = try emitProject(allocator, io, env, &graph);
        try w.print("{s}\n", .{root_zig});
    }
    try w.flush();
}

fn run(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, path: []const u8) !void {
    var graph = try loadProject(allocator, io, path);
    defer graph.deinit();
    if (!declaresMain(graph.root())) fatal("{s}:1:1: error: no `sub main()` to run", .{graph.root().display});
    const root_zig = try emitProject(allocator, io, env, &graph);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "zig", "run", root_zig },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) {
            std.debug.print("note: emitted Zig is in {s}\n", .{std.fs.path.dirname(root_zig) orelse "."});
            std.process.exit(code);
        },
        else => std.process.exit(1),
    }
}

fn declaresMain(m: *const modules.Module) bool {
    if (m.ir != .list) return false;
    for (m.ir.list[1..]) |top| {
        var decl = top;
        if (decl == .list and decl.list.len == 2 and decl.list[0] == .tag and decl.list[0].tag == .@"pub") decl = decl.list[1];
        if (decl != .list or decl.list.len < 2 or decl.list[0] != .tag) continue;
        if (decl.list[0].tag != .@"sub" and decl.list[0].tag != .@"fun") continue;
        if (std.mem.eql(u8, decl.list[1].getText(m.source), "main")) return true;
    }
    return false;
}

/// Write the runtime and every module to the output directory; return
/// the path of the root module's `.zig` file.
fn emitProject(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, graph: *modules.ModuleGraph) ![]const u8 {
    const dir = try outputDir(allocator, io, env, graph.root());

    try writeFile(io, try std.fs.path.join(allocator, &.{ dir, runtime.filename }), runtime.source);

    for (graph.modules.items) |*m| {
        var file_buffer: std.Io.Writer.Allocating = .init(allocator);
        var em = emit.Emitter.initWithSema(allocator, m.source, &file_buffer.writer, m.sema);
        defer em.deinit();
        try em.emit(m.ir);
        try writeFile(io, try std.fs.path.join(allocator, &.{ dir, m.out_basename }), file_buffer.written());
    }
    return std.fs.path.join(allocator, &.{ dir, graph.root().out_basename });
}

fn writeFile(io: std.Io, path: []const u8, contents: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        cwd.createDirPath(io, parent) catch |err| fatal("error: cannot create `{s}`: {s}", .{ parent, @errorName(err) });
    }
    cwd.writeFile(io, .{ .sub_path = path, .data = contents }) catch |err|
        fatal("error: cannot write `{s}`: {s}", .{ path, @errorName(err) });
}

/// `$RIG_OUT_DIR` when set (used as is). Otherwise a directory private to
/// this user and project under the cache home, emptied before each emit
/// so it holds exactly the current program.
fn outputDir(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, root: *const modules.Module) ![]const u8 {
    if (env.get("RIG_OUT_DIR")) |dir| if (dir.len > 0) return dir;

    const cache_home = if (env.get("XDG_CACHE_HOME")) |x| (if (x.len > 0) x else null) else null;
    const base = if (cache_home) |x|
        try std.fs.path.join(allocator, &.{ x, "rig" })
    else if (env.get("HOME")) |home|
        try std.fs.path.join(allocator, &.{ home, ".cache", "rig" })
    else
        fatal("error: set RIG_OUT_DIR, XDG_CACHE_HOME, or HOME for emitted Zig", .{});

    const project = try std.fmt.allocPrint(allocator, "{s}-{x:0>16}", .{ root.name, std.hash.Wyhash.hash(0, root.path) });
    const dir = try std.fs.path.join(allocator, &.{ base, project });
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    return dir;
}
