//! rig-oracle: the reference ownership checker, run by the test suite
//! beside the compiler's own (`src/ownership.zig`).
//!
//!   rig-oracle [options] PROGRAM...      PROGRAM is `path` or `name=path`
//!
//!   --list FILE       read more programs from FILE, one `name<TAB>path` a line
//!   --allow FILE      the classified differences (test/oracle/differences)
//!   --coverage FILE   the decided-function floors, one `set count` a line
//!   --set NAME        the set these programs are, for --coverage
//!   --explain FN      print the lowered core of every function named FN
//!   --stats           count the reasons the oracle abstains
//!   --planned         apply the Core's planned rules the oracle models:
//!                     a bare `break x` of an owner declared in the loop
//!                     moves it (a type holding a `Cell` is unique, and
//!                     headers read bare places, in every run)
//!   --sema            also decide the functions of a module whose
//!                     semantic checks failed (prod=sema), as a probe;
//!                     they count toward nothing
//!   -v                print every function's verdicts
//!
//! For each program it loads and checks the program as `rig check` does,
//! which gives production's verdict per function: rejected when the
//! ownership checker reported an error inside the function, accepted
//! otherwise, skipped when sema stopped the module first. It then lowers
//! every function of the program's own modules to the core (lower.zig)
//! and checks it (flow.zig), which accepts, rejects, or abstains. Each
//! function both decide differently is a difference. One the compiler
//! accepts and the oracle rejects always fails the run: it may be a
//! soundness hole. One the compiler rejects is reported, and listed in
//! the allowlist with its class once classified. The run also fails on
//! a stale allowlist entry, and on fewer decided functions than the
//! set's floor.
//!
//! A program may also state the oracle's own verdicts, one a line, which
//! every run checks, whatever the compiler decides:
//!
//!   # oracle: FUNCTION accept
//!   # oracle: FUNCTION reject RULE
//!   # oracle planned: FUNCTION reject RULE    (with --planned's rules)
//!
//! A verdict that differs, or no verdict, fails the run: these are the
//! oracle's own tests, one shape each. The oracle reads only the IR,
//! symbols, and types; it never
//! reads the compiler's ownership classifications (see test/run's lint).

const std = @import("std");
const lib = @import("rig_lib");
const lower = @import("lower.zig");
const flow = @import("flow.zig");
const core = @import("core.zig");

const modules = lib.modules;
const sema = lib.sema;
const parser = lib.parser;
const diag = lib.diag;
const ir = parser.ir;
const Sexp = parser.Sexp;

pub const Verdict = union(enum) {
    accept,
    reject: core.Finding,
    unknown: []const u8,
};

const Prod = enum { accept, reject, sema };

/// One function body: a `fun`, `sub`, method, `drop` body, or `test`.
pub const Unit = struct {
    name: []const u8,
    decl: Sexp,
    /// The struct or enum whose member it is, or `.nil`.
    owner: Sexp = .nil,
    /// A member of a generic type.
    generic_owner: bool = false,
};

const Allowed = struct { direction: []const u8, class: []const u8, used: bool = false };

const Options = struct {
    allow: ?[]const u8 = null,
    coverage: ?[]const u8 = null,
    set: []const u8 = "",
    explain: ?[]const u8 = null,
    stats: bool = false,
    verbose: bool = false,
    planned: bool = false,
    sema: bool = false,
};

const Totals = struct {
    programs: u32 = 0,
    functions: u32 = 0,
    checked: u32 = 0,
    accepted: u32 = 0,
    rejected: u32 = 0,
    unknown: u32 = 0,
    differences: u32 = 0,
    allowed: u32 = 0,
    failures: u32 = 0,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var opts: Options = .{};
    var programs: std.ArrayList([2][]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        const needs_value = std.mem.eql(u8, a, "--list") or std.mem.eql(u8, a, "--allow") or
            std.mem.eql(u8, a, "--coverage") or std.mem.eql(u8, a, "--set") or std.mem.eql(u8, a, "--explain");
        if (needs_value) {
            i += 1;
            if (i >= args.len) return usage(io, "missing value after an option");
            const v: []const u8 = args[i];
            if (std.mem.eql(u8, a, "--list")) {
                const text = try std.Io.Dir.cwd().readFileAlloc(io, v, arena, .limited(64 << 20));
                var lines = std.mem.tokenizeScalar(u8, text, '\n');
                while (lines.next()) |line| {
                    const tab = std.mem.findScalar(u8, line, '\t') orelse {
                        try programs.append(arena, .{ line, line });
                        continue;
                    };
                    try programs.append(arena, .{ line[0..tab], line[tab + 1 ..] });
                }
            } else if (std.mem.eql(u8, a, "--allow")) opts.allow = v else if (std.mem.eql(u8, a, "--coverage")) opts.coverage = v else if (std.mem.eql(u8, a, "--set")) opts.set = v else opts.explain = v;
        } else if (std.mem.eql(u8, a, "--stats")) {
            opts.stats = true;
        } else if (std.mem.eql(u8, a, "--planned")) {
            opts.planned = true;
        } else if (std.mem.eql(u8, a, "--sema")) {
            opts.sema = true;
        } else if (std.mem.eql(u8, a, "-v")) {
            opts.verbose = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return usage(io, "unknown option");
        } else if (std.mem.findScalar(u8, a, '=')) |eq| {
            try programs.append(arena, .{ a[0..eq], a[eq + 1 ..] });
        } else {
            try programs.append(arena, .{ a, a });
        }
    }

    var allow: std.StringHashMapUnmanaged(Allowed) = .empty;
    if (opts.allow) |path| try readAllowlist(arena, io, path, &allow);
    var seen_programs: std.StringHashMapUnmanaged(void) = .empty;
    var reasons: std.StringHashMapUnmanaged(u32) = .empty;

    var buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;

    var totals: Totals = .{};
    for (programs.items) |prog| {
        try seen_programs.put(arena, prog[0], {});
        var program_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer program_arena.deinit();
        try checkProgram(program_arena.allocator(), io, prog[0], prog[1], opts, &allow, &reasons, arena, out, &totals);
        try out.flush();
    }

    // An allowlist entry for a program of this run whose difference is gone.
    var it = allow.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.used) continue;
        const key = e.key_ptr.*;
        const sep = std.mem.findScalar(u8, key, 0).?;
        if (!seen_programs.contains(key[0..sep])) continue;
        try out.print("FIXED {s} {s}: the allowlisted difference is gone; remove it from the allowlist\n", .{ key[0..sep], key[sep + 1 ..] });
        totals.failures += 1;
    }

    if (opts.stats) {
        var list: std.ArrayList(struct { []const u8, u32 }) = .empty;
        var rit = reasons.iterator();
        while (rit.next()) |e| try list.append(arena, .{ e.key_ptr.*, e.value_ptr.* });
        std.mem.sort(struct { []const u8, u32 }, list.items, {}, struct {
            fn lt(_: void, x: struct { []const u8, u32 }, y: struct { []const u8, u32 }) bool {
                return x[1] > y[1];
            }
        }.lt);
        try out.print("abstentions by reason:\n", .{});
        for (list.items) |r| try out.print("{d:6}  {s}\n", .{ r[1], r[0] });
    }

    const decided = totals.accepted + totals.rejected;
    try out.print("oracle{s}{s}: {d} programs, {d} functions checked by ownership, {d} decided ({d} accepted, {d} rejected), {d} unknown; {d} differences, {d} allowlisted\n", .{
        if (opts.set.len > 0) " " else "", opts.set, totals.programs, totals.checked, decided, totals.accepted, totals.rejected, totals.unknown, totals.differences, totals.allowed,
    });
    if (opts.coverage) |path| {
        if (try readFloor(arena, io, path, opts.set)) |floor| {
            if (decided < floor) {
                try out.print("FAIL coverage: {d} decided functions, below the floor of {d} for `{s}` in {s}\n", .{ decided, floor, opts.set, path });
                totals.failures += 1;
            }
        }
    }
    try out.flush();
    return if (totals.failures > 0) 1 else 0;
}

fn usage(io: std.Io, why: []const u8) u8 {
    var buffer: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    stderr.interface.print("rig-oracle: {s}; see the comment at the top of test/oracle/main.zig\n", .{why}) catch {};
    stderr.interface.flush() catch {};
    return 2;
}

/// `test/oracle/differences`: `program function direction class note...`,
/// `#` comments and blank lines skipped.
fn readAllowlist(a: std.mem.Allocator, io: std.Io, path: []const u8, allow: *std.StringHashMapUnmanaged(Allowed)) !void {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 << 20));
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const program = words.next() orelse continue;
        const function = words.next() orelse continue;
        const direction = words.next() orelse continue;
        const class = words.next() orelse continue;
        // The compiler accepting what the oracle rejects is a possible
        // soundness hole: it always fails the run, so it is never listed.
        if (std.mem.eql(u8, direction, "prod-accepts")) {
            std.debug.print("{s}: `{s} {s}` lists a prod-accepts difference; those always fail and cannot be allowlisted\n", .{ path, program, function });
            return error.UnsoundAllowlisted;
        }
        const key = try std.mem.concat(a, u8, &.{ program, "\x00", function });
        try allow.put(a, key, .{ .direction = direction, .class = class });
    }
}

fn readFloor(a: std.mem.Allocator, io: std.Io, path: []const u8, set: []const u8) !?u32 {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const name = words.next() orelse continue;
        const count = words.next() orelse continue;
        if (std.mem.eql(u8, name, set)) return try std.fmt.parseInt(u32, count, 10);
    }
    return null;
}

fn checkProgram(
    a: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    path: []const u8,
    opts: Options,
    allow: *std.StringHashMapUnmanaged(Allowed),
    reasons: *std.StringHashMapUnmanaged(u32),
    keep: std.mem.Allocator,
    out: *std.Io.Writer,
    totals: *Totals,
) !void {
    totals.programs += 1;
    var graph = modules.ModuleGraph.init(a, io);
    graph.loadRoot(path) catch |err| {
        try out.print("{s}: cannot load: {s}\n", .{ name, @errorName(err) });
        totals.failures += 1;
        return;
    };
    // The generic bodies a call may run, in any module of the program.
    lower.program_modules = graph.modules.items;
    lower.copies_memo = .empty;
    for (graph.modules.items) |*m| {
        if (m.is_std or m.ir == .nil) continue;
        var units: std.ArrayList(Unit) = .empty;
        try collectUnits(a, m, &units);
        try checkStated(a, m, units.items, name, out, totals);
        for (units.items) |unit| {
            totals.functions += 1;
            const span = m.parser.span(unit.decl);
            const prod: Prod = if (!m.own_ran) .sema else blk: {
                for (m.sema.diagnostics.items[m.own_diags[0]..m.own_diags[1]]) |d| {
                    if (d.severity == .@"error" and d.module == 0 and d.pos >= span.start and d.pos < span.end) break :blk .reject;
                }
                break :blk .accept;
            };
            if (prod == .sema) {
                if (!opts.sema) continue;
                const verdict = try decide(a, m, unit, opts.planned, null);
                try out.print("{s} {s} prod=sema ref={s}", .{ name, unit.name, @tagName(verdict) });
                switch (verdict) {
                    .reject => |f| {
                        const lc = diag.lineCol(m.source, f.pos);
                        try out.print(" {s} {d}:{d} {s}", .{ @tagName(f.rule), lc.line, lc.col, f.reason });
                    },
                    .unknown => |why| try out.print(" ({s})", .{why}),
                    .accept => {},
                }
                try out.writeAll("\n");
                continue;
            }
            totals.checked += 1;
            const explain = if (opts.explain) |fname| std.mem.eql(u8, fname, unit.name) else false;
            const verdict = try decide(a, m, unit, opts.planned, if (explain) out else null);
            const qualified = if (graph.modules.items.len > 1 and m.id != 1)
                try std.mem.concat(a, u8, &.{ m.name, ".", unit.name })
            else
                unit.name;
            switch (verdict) {
                .accept => totals.accepted += 1,
                .reject => totals.rejected += 1,
                .unknown => |why| {
                    totals.unknown += 1;
                    if (opts.stats) {
                        const gop = try reasons.getOrPut(keep, why);
                        if (!gop.found_existing) {
                            gop.key_ptr.* = try keep.dupe(u8, why);
                            gop.value_ptr.* = 0;
                        }
                        gop.value_ptr.* += 1;
                    }
                },
            }
            const differs = switch (verdict) {
                .accept => prod == .reject,
                .reject => prod == .accept,
                .unknown => false,
            };
            if (!differs and !opts.verbose) continue;
            if (differs) totals.differences += 1;
            const direction = if (prod == .accept) "prod-accepts" else "prod-rejects";
            const key = try std.mem.concat(a, u8, &.{ name, "\x00", qualified });
            var allowed = false;
            if (differs) if (allow.getPtr(key)) |entry| {
                if (std.mem.eql(u8, entry.direction, direction)) {
                    entry.used = true;
                    allowed = true;
                    totals.allowed += 1;
                }
            };
            // Only the compiler accepting what the oracle rejects fails the
            // run; a stricter compiler is reported, and listed once classified.
            const fails = differs and prod == .accept;
            if (fails) totals.failures += 1;
            const mark = if (!differs) "" else if (fails) "DIFF " else if (allowed) "allowed " else "stricter ";
            try out.print("{s}{s} {s} prod={s} ref={s}", .{ mark, name, qualified, @tagName(prod), @tagName(verdict) });
            switch (verdict) {
                .reject => |f| {
                    const lc = diag.lineCol(m.source, f.pos);
                    try out.print(" {s} {d}:{d} {s}", .{ @tagName(f.rule), lc.line, lc.col, f.reason });
                },
                .unknown => |why| try out.print(" ({s})", .{why}),
                .accept => {},
            }
            try out.writeAll("\n");
        }
    }
}

/// Check the verdicts a module's `# oracle:` lines state.
fn checkStated(a: std.mem.Allocator, m: *const modules.Module, units: []const Unit, name: []const u8, out: *std.Io.Writer, totals: *Totals) !void {
    var lines = std.mem.tokenizeScalar(u8, m.source, '\n');
    while (lines.next()) |line| {
        const planned = std.mem.startsWith(u8, line, "# oracle planned: ");
        if (!planned and !std.mem.startsWith(u8, line, "# oracle: ")) continue;
        var words = std.mem.tokenizeScalar(u8, line[if (planned) "# oracle planned: ".len else "# oracle: ".len..], ' ');
        const function = words.next() orelse "";
        const want = words.next() orelse "";
        const rule = words.next();
        const unit = for (units) |u| {
            if (std.mem.eql(u8, u.name, function)) break u;
        } else {
            try out.print("FAIL {s}: `{s}` states a verdict for `{s}`, which is not a function here\n", .{ name, line, function });
            totals.failures += 1;
            continue;
        };
        const verdict = try decide(a, m, unit, planned, null);
        const ok = switch (verdict) {
            .accept => std.mem.eql(u8, want, "accept") and rule == null,
            .reject => |f| std.mem.eql(u8, want, "reject") and (rule == null or std.mem.eql(u8, rule.?, @tagName(f.rule))),
            .unknown => false,
        };
        if (ok) continue;
        try out.print("FAIL {s} {s}: `{s}`, but the oracle decides {s}", .{ name, function, line, @tagName(verdict) });
        switch (verdict) {
            .reject => |f| {
                const lc = diag.lineCol(m.source, f.pos);
                try out.print(" {s} {d}:{d} {s}", .{ @tagName(f.rule), lc.line, lc.col, f.reason });
            },
            .unknown => |why| try out.print(" ({s})", .{why}),
            .accept => {},
        }
        try out.writeAll("\n");
        totals.failures += 1;
    }
}

/// The function bodies of a module, in declaration order.
fn collectUnits(a: std.mem.Allocator, m: *const modules.Module, units: *std.ArrayList(Unit)) !void {
    var names: std.StringHashMapUnmanaged(u32) = .empty;
    for (ir.Module.decls(m.ir)) |decl| try collectDecl(a, m, decl, .nil, false, units, &names);
}

fn collectDecl(a: std.mem.Allocator, m: *const modules.Module, decl: Sexp, owner: Sexp, generic: bool, units: *std.ArrayList(Unit), names: *std.StringHashMapUnmanaged(u32)) !void {
    const kind = decl.kind() orelse return;
    switch (kind) {
        .@"pub" => try collectDecl(a, m, ir.Pub.decl(decl), owner, generic, units, names),
        .fun, .sub, .drop_decl, .@"test" => {
            if (ir.get(decl, .body) == .nil) return;
            const base = switch (kind) {
                .drop_decl => "drop",
                .@"test" => ir.Test.name(decl).getText(m.source),
                else => ir.get(decl, .name).getText(m.source),
            };
            var name = if (owner != .nil)
                try std.mem.concat(a, u8, &.{ ir.get(owner, .name).getText(m.source), ".", base })
            else if (kind == .@"test")
                try std.mem.concat(a, u8, &.{ "test", base })
            else
                base;
            // Spaces would split the allowlist's fields.
            if (std.mem.findScalar(u8, name, ' ') != null) {
                const copy = try a.dupe(u8, name);
                std.mem.replaceScalar(u8, copy, ' ', '_');
                name = copy;
            }
            const gop = try names.getOrPut(a, name);
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
                name = try a.print("{s}#{d}", .{ name, gop.value_ptr.* });
            } else gop.value_ptr.* = 1;
            try units.append(a, .{ .name = name, .decl = decl, .owner = owner, .generic_owner = generic });
        },
        .@"struct", .@"enum" => for (ir.rest(decl, .members)) |member| try collectDecl(a, m, member, decl, false, units, names),
        .generic_struct, .generic_enum => for (ir.rest(decl, .members)) |member| try collectDecl(a, m, member, decl, true, units, names),
        else => {},
    }
}

/// The reference verdict on one function.
fn decide(a: std.mem.Allocator, m: *const modules.Module, unit: Unit, planned: bool, explain: ?*std.Io.Writer) !Verdict {
    var func = lower.lowerUnit(a, m, unit, planned) catch |err| switch (err) {
        error.Abstain => return .{ .unknown = lower.abstain_reason },
        else => |e| return e,
    };
    if (explain) |w| try core.dump(&func, w);
    if (try flow.check(a, &func)) |finding| return .{ .reject = finding };
    return .accept;
}
