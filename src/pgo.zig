//! `rig build --release --pgo -- WORKLOAD`: optimize the executable by
//! LLVM's profile-guided optimization, trained on where a workload runs
//! it (Linux, a program that links no C library). Zig has no flag for
//! it, so the build takes Zig's LLVM bitcode of the program and
//! finishes it with Zig's clang (`zig cc`) and Zig's linker:
//!
//! 1. Zig writes the program's bitcode (`-femit-llvm-bc`), once.
//! 2. `zig cc -fprofile-generate` compiles it with LLVM's counters, and
//!    Zig links that with LLVM's profile runtime (`libclang_rt.profile`)
//!    and the profile writer (`pgo_dump.c`), which the program's runtime
//!    calls as it ends (`writeProfile` in runtime.zig): a program
//!    without libc never runs the runtime's own `atexit` writer.
//! 3. The workload runs that executable; each process it ends writes a
//!    raw profile, and `llvm-profdata merge` makes them one.
//! 4. `zig cc -fprofile-use` compiles the same bitcode by the profile,
//!    and Zig links the executable.
//!
//! The two compiles read one bitcode, so every function of the profile
//! has its name in the optimized build. `--pgo-profile=FILE` keeps the
//! profile in FILE, and with no workload builds by FILE as it is; a
//! profile of an older build fits the functions that have not changed,
//! and the build says how many it fit.
//!
//! The root module of a `--pgo` package declares `__rig_pgo`, which
//! makes the runtime call `__rig_pgo_dump` as the program ends: the
//! writer in the instrumented build, a function that does nothing in the
//! optimized one. A build without `--pgo` declares nothing and is
//! unchanged. Everything else is in this file and `pgo_dump.c`: the
//! feature is removed by deleting them, `writeProfile` in the runtime,
//! the `--pgo` and `--pgo-profile` flags in main.zig, and
//! test/cli/pgo.sh.

const std = @import("std");
const builtin = @import("builtin");

/// The writer the instrumented build links, built for each build with
/// the directory its profiles go in.
const dump_source = @embedFile("pgo_dump.c");

/// The tools `--pgo` runs, found before the build so a missing one fails
/// at once: llvm-profdata and the profile runtime of the LLVM Zig is
/// built on, whose formats change with LLVM's major version.
pub const Tools = struct {
    /// LLVM's major version in Zig (`zig cc --version`).
    llvm: u32,
    profdata: []const u8,
    /// `libclang_rt.profile` for this machine's processor, which the
    /// instrumented build links; empty when the build trains nothing.
    runtime: []const u8,

    /// The tools of LLVM `NN`, Zig's: `llvm-profdata-NN` on PATH, then
    /// `/usr/lib/llvm-NN/bin/llvm-profdata`, then `llvm-profdata` on
    /// PATH if it says it is NN; the runtime beside it, in its
    /// installation's `lib/clang/NN/lib/`. An error names what is
    /// missing.
    pub fn find(allocator: std.mem.Allocator, io: std.Io, path: []const u8, zig: []const u8, train: bool) !Tools {
        if (builtin.os.tag != .linux) fail("`--pgo` needs Linux: it builds an executable that links no C library, as Rig's Linux builds do", .{});
        const version = try run(allocator, io, &.{ zig, "cc", "--version" }, true);
        const llvm = majorAfter(version.out, "clang version ") orelse fail("cannot read the LLVM version of Zig's clang (`{s} cc --version`):\n{s}", .{ zig, version.out });
        const install = "`--pgo` needs LLVM {d}'s llvm-profdata and profile runtime, the LLVM Zig is built on: install Ubuntu's `llvm-{d}` and `libclang-rt-{d}-dev`";
        const profdata = (try findProfdata(allocator, io, path, llvm)) orelse fail(install, .{ llvm, llvm, llvm });
        const runtime = if (!train) "" else (try findRuntime(allocator, io, profdata, llvm)) orelse
            fail(install ++ " (found {s}, but no libclang_rt.profile beside it)", .{ llvm, llvm, llvm, profdata });
        return .{ .llvm = llvm, .profdata = profdata, .runtime = runtime };
    }
};

/// How the program is built: what `rig build` hands Zig.
pub const Build = struct {
    zig: []const u8,
    /// The mode's flag and the flags after it (`-Osafe`, frame pointers).
    flags: []const []const u8,
    cache: []const u8,
    /// The package's root `.zig` file.
    root: []const u8,
    /// The executable to write.
    out: []const u8,
    /// What else the final link takes (BOLT's relocations).
    link: []const []const u8,
    /// A directory of the package's, for the bitcode, the objects, and
    /// the raw profiles; removed after.
    work: []const u8,
};

/// Build `b.out` by profile: trained by `workload` (kept in `profile`
/// when given), or, with no workload, by `profile`. A failure of Zig or
/// clang exits with its status, after its own report.
pub fn build(allocator: std.mem.Allocator, io: std.Io, tools: Tools, b: Build, workload: []const []const u8, profile: ?[]const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, b.work) catch {};
    cwd.createDirPath(io, b.work) catch |err| fail("cannot create `{s}`: {s}", .{ b.work, @errorName(err) });
    const work = cwd.realPathFileAlloc(io, b.work, allocator) catch |err| fail("cannot find `{s}`: {s}", .{ b.work, @errorName(err) });
    defer cwd.deleteTree(io, work) catch {};
    const bitcode = try std.fs.path.join(allocator, &.{ work, "program.bc" });
    const target = @tagName(builtin.cpu.arch) ++ "-linux-none";
    // Zig's native processor, no PIC (a static executable), clang's -O3
    // with merged functions, as Zig's own pipeline has.
    const cc: []const []const u8 = &.{ b.zig, "cc", "-target", target, "-mcpu=native", "-c", "-O3", "-fno-PIC", "-fno-PIE", "-Xclang", "-fmerge-functions", "-Wno-override-module" };

    try runZig(allocator, io, &.{ &.{ b.zig, "build-exe" }, b.flags, &.{ "--cache-dir", b.cache, b.root, try allocPrint(allocator, "-femit-llvm-bc={s}", .{bitcode}), "-fno-emit-bin" } });
    const merged = profile orelse try std.fs.path.join(allocator, &.{ work, "program.profdata" });
    if (workload.len > 0) {
        const raw = try std.fs.path.join(allocator, &.{ work, "raw" });
        cwd.createDirPath(io, raw) catch |err| fail("cannot create `{s}`: {s}", .{ raw, @errorName(err) });
        const dump_c = try std.fs.path.join(allocator, &.{ work, "pgo_dump.c" });
        const dump_o = try std.fs.path.join(allocator, &.{ work, "pgo_dump.o" });
        const counted = try std.fs.path.join(allocator, &.{ work, "counted.o" });
        cwd.writeFile(io, .{ .sub_path = dump_c, .data = dump_source }) catch |err| fail("cannot write `{s}`: {s}", .{ dump_c, @errorName(err) });
        try clang(allocator, io, &.{ &.{ b.zig, "cc", "-target", target, "-c", "-O2", "-ffreestanding", "-fno-stack-protector", "-fno-PIC", "-fno-PIE", try allocPrint(allocator, "-DRIG_PGO_DIR=\"{s}\"", .{raw}), dump_c, "-o", dump_o } });
        try clang(allocator, io, &.{ cc, &.{ "-fprofile-generate", bitcode, "-o", counted } });
        try runZig(allocator, io, &.{ &.{ b.zig, "build-exe" }, b.flags, &.{ "--cache-dir", b.cache, counted, dump_o, tools.runtime, try allocPrint(allocator, "-femit-bin={s}", .{b.out}) } });
        _ = try run(allocator, io, workload, false);
        var raws: std.ArrayList([]const u8) = .empty;
        var dir = cwd.openDir(io, raw, .{ .iterate = true }) catch |err| fail("cannot read `{s}`: {s}", .{ raw, @errorName(err) });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| if (std.mem.endsWith(u8, e.name, ".profraw")) try raws.append(allocator, try std.fs.path.join(allocator, &.{ raw, e.name }));
        if (raws.items.len == 0) fail("`{s}` wrote no profile: the workload must run the executable `rig build` wrote, `{s}`, to its end", .{ workload[0], b.out });
        const m = try run(allocator, io, try std.mem.concat(allocator, []const u8, &.{ &.{ tools.profdata, "merge", "-o", merged }, raws.items }), true);
        if (m.code != 0) fail("llvm-profdata could not merge the workload's profiles:\n{s}", .{m.out});
    } else if (!exists(io, merged)) fail("no profile `{s}`: train one with a workload after `--`", .{merged});

    // The optimized build's `__rig_pgo_dump` does nothing.
    const none_c = try std.fs.path.join(allocator, &.{ work, "pgo_none.c" });
    const none_o = try std.fs.path.join(allocator, &.{ work, "pgo_none.o" });
    cwd.writeFile(io, .{ .sub_path = none_c, .data = "void __rig_pgo_dump(void) {}\n" }) catch |err| fail("cannot write `{s}`: {s}", .{ none_c, @errorName(err) });
    try clang(allocator, io, &.{ &.{ b.zig, "cc", "-target", target, "-c", "-O2", "-fno-PIC", "-fno-PIE", none_c, "-o", none_o } });
    const optimized = try std.fs.path.join(allocator, &.{ work, "optimized.o" });
    const r = try run(allocator, io, try std.mem.concat(allocator, []const u8, &.{ cc, &.{ try allocPrint(allocator, "-fprofile-use={s}", .{merged}), bitcode, "-o", optimized } }), true);
    if (r.code != 0) {
        std.debug.print("{s}", .{r.out});
        std.process.exit(r.code);
    }
    stale(r.out, merged);
    try runZig(allocator, io, &.{ &.{ b.zig, "build-exe" }, b.flags, &.{ "--cache-dir", b.cache, optimized, none_o }, b.link, &.{try allocPrint(allocator, "-femit-bin={s}", .{b.out})} });
}

/// What clang says of a profile that does not fit the build, said as a
/// warning of the build's: a profile of an older program, whose changed
/// functions (a "hash mismatch" each) are built without it.
fn stale(out: []const u8, profile: []const u8) void {
    const n = std.mem.count(u8, out, "function control flow change detected (hash mismatch)");
    if (n > 0) std.debug.print("warning: the profile `{s}` is out of date for {d} function{s}, changed since it was trained, which {s} built without it: train it again with a workload\n", .{ profile, n, if (n == 1) "" else "s", if (n == 1) "is" else "are" });
    if (std.mem.indexOf(u8, out, "no profile data available") != null)
        std.debug.print("warning: the profile `{s}` has nothing of this program: train it with a workload that runs it\n", .{profile});
}

/// Run Zig; its failure, which it has reported, ends `rig` with its
/// status.
fn runZig(allocator: std.mem.Allocator, io: std.Io, parts: []const []const []const u8) !void {
    const r = try run(allocator, io, try std.mem.concat(allocator, []const u8, parts), false);
    if (r.code != 0) std.process.exit(r.code);
}

/// Run clang, showing what it says only when it fails.
fn clang(allocator: std.mem.Allocator, io: std.Io, parts: []const []const []const u8) !void {
    const r = try run(allocator, io, try std.mem.concat(allocator, []const u8, parts), true);
    if (r.code == 0) return;
    std.debug.print("{s}", .{r.out});
    std.process.exit(r.code);
}

/// The number before the first `.` after `prefix` in `text`.
fn majorAfter(text: []const u8, prefix: []const u8) ?u32 {
    const at = std.mem.indexOf(u8, text, prefix) orelse return null;
    const rest = text[at + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
}

fn findProfdata(allocator: std.mem.Allocator, io: std.Io, path: []const u8, llvm: u32) !?[]const u8 {
    const versioned = try allocPrint(allocator, "llvm-profdata-{d}", .{llvm});
    if (try onPath(allocator, io, path, versioned)) |p| return p;
    const installed = try allocPrint(allocator, "/usr/lib/llvm-{d}/bin/llvm-profdata", .{llvm});
    if (executable(io, installed)) return installed;
    const plain = (try onPath(allocator, io, path, "llvm-profdata")) orelse return null;
    const v = try run(allocator, io, &.{ plain, "--version" }, true);
    return if (majorAfter(v.out, "LLVM version ") == llvm) plain else null;
}

/// `libclang_rt.profile` in the LLVM installation `profdata` is part of
/// (`PREFIX/bin/llvm-profdata`, links followed), by either of LLVM's
/// layouts: `lib/clang/NN/lib/linux/libclang_rt.profile-ARCH.a` or
/// `lib/clang/NN/lib/ARCH-unknown-linux-gnu/libclang_rt.profile.a`.
fn findRuntime(allocator: std.mem.Allocator, io: std.Io, profdata: []const u8, llvm: u32) !?[]const u8 {
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, profdata, allocator) catch return null;
    const prefix = std.fs.path.dirname(std.fs.path.dirname(real) orelse return null) orelse return null;
    const arch = @tagName(builtin.cpu.arch);
    const candidates = [_][]const u8{
        try allocPrint(allocator, "{s}/lib/clang/{d}/lib/linux/libclang_rt.profile-{s}.a", .{ prefix, llvm, arch }),
        try allocPrint(allocator, "{s}/lib/clang/{d}/lib/{s}-unknown-linux-gnu/libclang_rt.profile.a", .{ prefix, llvm, arch }),
    };
    for (candidates) |c| if (exists(io, c)) return c;
    return null;
}

fn onPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8, name: []const u8) !?[]const u8 {
    var dirs = std.mem.tokenizeScalar(u8, path, ':');
    while (dirs.next()) |d| {
        const candidate = try std.fs.path.join(allocator, &.{ d, name });
        if (executable(io, candidate)) return candidate;
    }
    return null;
}

fn exists(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

fn executable(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file and st.permissions.toMode() & 0o111 != 0;
}

/// Run `argv`, its output this process's, or kept (`capture`, stdout and
/// stderr together); its status.
fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, capture: bool) !struct { code: u8, out: []const u8 } {
    if (capture) {
        const r = std.process.run(allocator, io, .{ .argv = argv, .stdout_limit = .limited(1 << 26), .stderr_limit = .limited(1 << 26) }) catch |err|
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

fn allocPrint(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(allocator, fmt, args);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

test "the LLVM major version in a tool's banner" {
    try std.testing.expectEqual(@as(?u32, 22), majorAfter("clang version 22.1.8 (https://github.com/llvm/llvm-project ...)", "clang version "));
    try std.testing.expectEqual(@as(?u32, 22), majorAfter("Ubuntu LLVM version 22.1.2\n  Optimized build.", "LLVM version "));
    try std.testing.expectEqual(@as(?u32, null), majorAfter("zig 0.17.0", "clang version "));
}
