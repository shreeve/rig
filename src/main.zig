//! Rig Compiler — CLI Driver
//!
//! Subcommands:
//!   rig parse     <file.rig>  — print raw S-expression tree (M0)
//!   rig tokens    <file.rig>  — dump token stream (debug)
//!   rig normalize <file.rig>  — print semantic IR             (M1, stub for now)
//!   rig check     <file.rig>  — run ownership/borrow checker  (M2, stub for now)
//!   rig build     <file.rig>  — emit Zig source               (M3, stub for now)
//!   rig run       <file.rig>  — build + zig run                (M4, stub for now)

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const normalize = @import("normalize.zig");

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
    \\  parse      Print raw S-expression tree
    \\  tokens     Dump token stream (debug)
    \\  normalize  Print normalized semantic IR    [M1, stub]
    \\  check      Run ownership / borrow checker  [M2, stub]
    \\  build      Emit Zig source                 [M3, stub]
    \\  run        Build + zig run                 [M4, stub]
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
        .check, .build, .run => {
            std.debug.print("Subcommand `{s}` not yet implemented (deferred to milestone {s}).\n", .{
                sub,
                switch (mode) {
                    .check => "M2",
                    .build => "M3",
                    .run => "M4",
                    else => unreachable,
                },
            });
            std.process.exit(2);
        },
        .help => unreachable,
    }
}

fn parseAndPrint(allocator: std.mem.Allocator, io: std.Io, source: []const u8) !void {
    var p = parser.Parser.init(allocator, source);
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
    var p = parser.Parser.init(allocator, source);
    defer p.deinit();

    const raw = p.parseProgram() catch {
        p.printError();
        std.process.exit(1);
    };

    var alloc = allocator;
    var n = normalize.Normalizer.init(&alloc);
    const out = try n.normalize(raw);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const w: *std.Io.Writer = &stdout_writer.interface;
    try out.write(source, w);
    try w.writeAll("\n");
    try w.flush();
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
