//! `rig build --release --bolt -- WORKLOAD`: lay the executable out again
//! with LLVM's BOLT, by where a workload runs it (Linux). The build keeps
//! the linker's relocations (`zig_args`), which BOLT needs to move code;
//! `perf record -j any,u` runs the workload, recording the branches the
//! processor takes; perf2bolt turns that into BOLT's profile; and
//! llvm-bolt rewrites the executable with its blocks ordered by heat
//! (ext-tsp), cold code split off, functions in call order (cdsort), and
//! identical functions folded. `--bolt-profile=FILE` keeps that profile
//! in FILE, and with no workload lays the build out by FILE as it is,
//! matching what changed since (`-infer-stale-profile`).
//!
//! Everything BOLT needs is in this file. The feature is removed by
//! deleting it, the `--bolt` and `--bolt-profile` flags in main.zig, and
//! test/cli/bolt.sh.

const std = @import("std");
const builtin = @import("builtin");

/// What the build passes Zig: keep the relocations.
pub const zig_args: []const []const u8 = &.{"--emit-relocs"};

/// The tools `--bolt` runs, found before the build so a missing one
/// fails at once.
pub const Tools = struct {
    perf: []const u8,
    perf2bolt: []const u8,
    llvm_bolt: []const u8,

    /// perf, perf2bolt, and llvm-bolt on PATH, the last two also by
    /// LLVM's versioned names (`llvm-bolt-21`) and in
    /// `/usr/lib/llvm-NN/bin`; an error naming what is missing.
    pub fn find(allocator: std.mem.Allocator, io: std.Io, path: []const u8, record: bool) !Tools {
        if (builtin.os.tag != .linux) fail("`--bolt` needs Linux: BOLT lays out Linux executables, by a profile perf records", .{});
        const missing = "`--bolt` needs LLVM's {s}: install BOLT, as Ubuntu's `bolt-NN` package (`bolt-21` for LLVM 21); Ubuntu's package named plain `bolt` is the Thunderbolt daemon";
        return .{
            .perf = if (!record) "" else (try which(allocator, io, path, "perf", false)) orelse fail("`--bolt` needs perf to record the workload: install Linux's perf (Ubuntu's linux-tools)", .{}),
            .perf2bolt = if (!record) "" else (try which(allocator, io, path, "perf2bolt", true)) orelse fail(missing, .{"perf2bolt"}),
            .llvm_bolt = (try which(allocator, io, path, "llvm-bolt", true)) orelse fail(missing, .{"llvm-bolt"}),
        };
    }
};

/// BOLT's own word for how many more samples it wants, which `--bolt`
/// passes on as a warning: a short workload gives too few for a layout
/// as good as BOLT could make.
const more_samples = "optimize better with ";

/// Lay `exe` out again: record `workload` under perf into BOLT's profile
/// (kept at `profile` when given), or, with no workload, read `profile`.
pub fn optimize(allocator: std.mem.Allocator, io: std.Io, tools: Tools, exe: []const u8, workload: []const []const u8, profile: ?[]const u8) !void {
    const data = try std.fmt.allocPrint(allocator, "{s}.perf.data", .{exe});
    const laid = try std.fmt.allocPrint(allocator, "{s}.bolt", .{exe});
    const fdata = profile orelse try std.fmt.allocPrint(allocator, "{s}.fdata", .{exe});
    const cwd = std.Io.Dir.cwd();
    defer {
        cwd.deleteFile(io, data) catch {};
        cwd.deleteFile(io, laid) catch {};
        if (profile == null) cwd.deleteFile(io, fdata) catch {};
    }
    if (workload.len > 0) {
        cwd.deleteFile(io, data) catch {};
        const record: []const []const u8 = &.{ tools.perf, "record", "-q", "-e", "cycles:u", "-c", "20011", "-j", "any,u", "-o", data, "--" };
        _ = try run(allocator, io, try std.mem.concat(allocator, []const u8, &.{ record, workload }), false);
        const st = cwd.statFile(io, data, .{}) catch null;
        if (st == null or st.?.size == 0) fail("perf recorded nothing of `{s}`: the workload must run the executable `rig build` wrote, on a processor whose branches perf can record (`perf record -j any,u`)", .{workload[0]});
        const conv = try run(allocator, io, &.{ tools.perf2bolt, "-p", data, "-o", fdata, exe }, true);
        if (conv.code != 0) fail("perf2bolt could not read the profile of `{s}`:\n{s}", .{ exe, conv.out });
    }
    const args: []const []const u8 = &.{ tools.llvm_bolt, exe, "-o", laid, try std.fmt.allocPrint(allocator, "-data={s}", .{fdata}), "-reorder-blocks=ext-tsp", "-reorder-functions=cdsort", "-split-functions", "-split-all-cold", "-icf=1", "-infer-stale-profile" };
    const r = try run(allocator, io, args, true);
    if (r.code != 0) fail("llvm-bolt could not lay out `{s}`:\n{s}", .{ exe, r.out });
    if (std.mem.indexOf(u8, r.out, more_samples)) |at| {
        const rest = r.out[at + more_samples.len ..];
        std.debug.print("warning: BOLT wants {s} the samples the workload gave: run it longer, or more times\n", .{rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len]});
    }
    cwd.rename(laid, cwd, exe, io) catch |err| fail("cannot replace `{s}`: {s}", .{ exe, @errorName(err) });
}

/// Run `argv`, its output this process's, or kept (`capture`, stdout and
/// stderr together); its status.
fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, capture: bool) !struct { code: u8, out: []const u8 } {
    if (capture) {
        const r = std.process.run(allocator, io, .{ .argv = argv, .stdout_limit = .limited(1 << 24), .stderr_limit = .limited(1 << 24) }) catch |err|
            fail("cannot run `{s}`: {s}", .{ argv[0], @errorName(err) });
        const code: u8 = switch (r.term) {
            .exited => |c| c,
            else => 255,
        };
        return .{ .code = code, .out = try std.mem.concat(allocator, u8, &.{ r.stdout, r.stderr }) };
    }
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .inherit, .stdout = .inherit, .stderr = .inherit }) catch |err|
        fail("cannot run `{s}`: {s}", .{ argv[0], @errorName(err) });
    const code: u8 = switch (try child.wait(io)) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .out = "" };
}

/// An executable `name` in a directory of `path`; with `llvm`, also
/// `name-NN` there and `/usr/lib/llvm-NN/bin/name`, newest first.
fn which(allocator: std.mem.Allocator, io: std.Io, path: []const u8, name: []const u8, llvm: bool) !?[]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(allocator, name);
    if (llvm) {
        var v: u32 = 40;
        while (v >= 14) : (v -= 1) try names.append(allocator, try std.fmt.allocPrint(allocator, "{s}-{d}", .{ name, v }));
    }
    for (names.items) |n| {
        var dirs = std.mem.tokenizeScalar(u8, path, ':');
        while (dirs.next()) |d| {
            const candidate = try std.fs.path.join(allocator, &.{ d, n });
            if (executable(io, candidate)) return candidate;
        }
    }
    if (llvm) {
        var v: u32 = 40;
        while (v >= 14) : (v -= 1) {
            const candidate = try std.fmt.allocPrint(allocator, "/usr/lib/llvm-{d}/bin/{s}", .{ v, name });
            if (executable(io, candidate)) return candidate;
        }
    }
    return null;
}

fn executable(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file and st.permissions.toMode() & 0o111 != 0;
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
