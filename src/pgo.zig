//! `rig build --release --pgo -- WORKLOAD`: optimize the executable by
//! LLVM's profile-guided optimization, trained on where a workload runs
//! it (on Linux, a program that links no C library; on the Mac, any).
//! Zig has no flag for it, so the build takes Zig's LLVM bitcode of the
//! program and finishes it with Zig's clang (`zig cc`) and Zig's linker:
//!
//! 1. Zig writes the program's bitcode (`-femit-llvm-bc`), once, as it
//!    is before LLVM's passes, and runs none of them
//!    (`-fopt-bisect-limit=0`): clang runs them in steps 2 and 4, and
//!    Zig, asked for no executable, would run them only to drop what
//!    they made. With `rig build --strip` the bitcode has no debug
//!    information, which is most of what Zig writes for a large program.
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
//! On the Mac the tools are Apple's (`xcrun`), whose LLVM need not be
//! Zig's: the formats of a raw and a merged profile have changed rarely,
//! and a change would fail loudly at the merge. Zig's Mach-O linker
//! writes the counters' records so no llvm-profdata can read them, so
//! the instrumented build is linked by Apple's `ld`; the optimized one,
//! which has no counters, by Zig's, as every Mac build is. Both objects
//! keep the program's section apart as `rig build` does there
//! (`Build.apart`).
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

/// Whether this `rig` builds for the Mac, whose tools and instrumented
/// link are Apple's.
const mac = builtin.os.tag == .macos;

/// The target and position flags of every C compile: a static
/// executable on Linux, position-independent code on the Mac, which
/// requires it.
const target = @tagName(builtin.cpu.arch) ++ if (mac) "-macos" else "-linux-none";
const position: []const []const u8 = if (mac) &.{} else &.{ "-fno-PIC", "-fno-PIE" };

/// The tools `--pgo` runs, found before the build so a missing one fails
/// at once: llvm-profdata and the profile runtime, on Linux of the LLVM
/// Zig is built on, whose formats change with LLVM's major version, and
/// on the Mac Apple's.
pub const Tools = struct {
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
        if (mac) return findApple(allocator, io, train);
        if (builtin.os.tag != .linux) fail("`--pgo` needs Linux or the Mac", .{});
        const version = try run(allocator, io, &.{ zig, "cc", "--version" }, true);
        const llvm = majorAfter(version.out, "clang version ") orelse fail("cannot read the LLVM version of Zig's clang (`{s} cc --version`):\n{s}", .{ zig, version.out });
        const install = "`--pgo` needs LLVM {d}'s llvm-profdata and profile runtime, the LLVM Zig is built on: install Ubuntu's `llvm-{d}` and `libclang-rt-{d}-dev`";
        const profdata = (try findProfdata(allocator, io, path, llvm)) orelse fail(install, .{ llvm, llvm, llvm });
        const runtime = if (!train) "" else (try findRuntime(allocator, io, profdata, llvm)) orelse
            fail(install ++ " (found {s}, but no libclang_rt.profile beside it)", .{ llvm, llvm, llvm, profdata });
        return .{ .profdata = profdata, .runtime = runtime };
    }

    /// The Mac's tools, by `xcrun`, which also tells clang where the
    /// system's libraries are: llvm-profdata, and the profile runtime in
    /// clang's resource directory.
    fn findApple(allocator: std.mem.Allocator, io: std.Io, train: bool) !Tools {
        const install = "`--pgo` needs Apple's command-line tools (`xcode-select --install`), whose llvm-profdata, clang, and profile runtime it runs";
        const profdata = try xcrun(allocator, io, "llvm-profdata") orelse fail(install, .{});
        if (!train) return .{ .profdata = profdata, .runtime = "" };
        const resource = try run(allocator, io, &.{ "xcrun", "clang", "-print-resource-dir" }, true);
        const dir = std.mem.trim(u8, resource.out, " \n");
        const runtime = try allocPrint(allocator, "{s}/lib/darwin/libclang_rt.profile_osx.a", .{dir});
        if (resource.code != 0 or !exists(io, runtime)) fail(install ++ " (no `{s}`)", .{runtime});
        return .{ .profdata = profdata, .runtime = runtime };
    }
};

/// The path `xcrun` finds for `tool`, or null.
fn xcrun(allocator: std.mem.Allocator, io: std.Io, tool: []const u8) !?[]const u8 {
    const r = std.process.run(allocator, io, .{ .argv = &.{ "xcrun", "--find", tool }, .stdout_limit = .limited(1 << 16), .stderr_limit = .limited(1 << 16) }) catch return null;
    if (!r.term.success()) return null;
    return std.mem.trim(u8, r.stdout, " \n");
}

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
    /// Finish an executable as `rig build` does, so the build that trains
    /// runs what the program will: dense stacks are off until it is done,
    /// and their paths would train as cold.
    seal: *const fn (std.mem.Allocator, std.Io, []const u8) void,
    /// On the Mac, in a program built to be preempted: write the object
    /// (first path) to the second with its program section kept apart,
    /// as `rig build` does before it links. The processor reserves x15
    /// for such a program.
    apart: ?*const fn (std.mem.Allocator, std.Io, []const u8, []const u8) anyerror!void = null,
};

/// `object`, or its copy with the program section kept apart.
fn apartFrom(allocator: std.mem.Allocator, io: std.Io, b: Build, object: []const u8) ![]const u8 {
    const keep = b.apart orelse return object;
    const out = try allocPrint(allocator, "{s}-apart.o", .{object});
    try keep(allocator, io, object, out);
    return out;
}

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
    // Zig's native processor, the target's position flags, clang's -O3
    // with merged functions, as Zig's own pipeline has.
    const cpu: []const u8 = if (b.apart != null) "-mcpu=native+reserve_x15" else "-mcpu=native";
    const cc: []const []const u8 = try std.mem.concat(allocator, []const u8, &.{ &.{ b.zig, "cc", "-target", target, cpu, "-c", "-O3" }, position, &.{ "-Xclang", "-fmerge-functions", "-Wno-override-module" } });

    try writeBitcode(allocator, io, try std.mem.concat(allocator, []const u8, &.{ &.{ b.zig, "build-exe" }, b.flags, &.{ "--cache-dir", b.cache, b.root, try allocPrint(allocator, "-femit-llvm-bc={s}", .{bitcode}), "-fno-emit-bin", "-fopt-bisect-limit=0" } }), try std.fs.path.join(allocator, &.{ work, "bitcode.log" }));
    const merged = profile orelse try std.fs.path.join(allocator, &.{ work, "program.profdata" });
    if (workload.len > 0) {
        const raw = try std.fs.path.join(allocator, &.{ work, "raw" });
        cwd.createDirPath(io, raw) catch |err| fail("cannot create `{s}`: {s}", .{ raw, @errorName(err) });
        const dump_c = try std.fs.path.join(allocator, &.{ work, "pgo_dump.c" });
        const dump_o = try std.fs.path.join(allocator, &.{ work, "pgo_dump.o" });
        const counted = try std.fs.path.join(allocator, &.{ work, "counted.o" });
        cwd.writeFile(io, .{ .sub_path = dump_c, .data = dump_source }) catch |err| fail("cannot write `{s}`: {s}", .{ dump_c, @errorName(err) });
        try clang(allocator, io, &.{ &.{ b.zig, "cc", "-target", target, "-c", "-O2", "-ffreestanding", "-fno-stack-protector" }, position, &.{ try allocPrint(allocator, "-DRIG_PGO_DIR=\"{s}\"", .{raw}), dump_c, "-o", dump_o } });
        try clang(allocator, io, &.{ cc, &.{ "-fprofile-generate", bitcode, "-o", counted } });
        const counted_apart = try apartFrom(allocator, io, b, counted);
        if (mac)
            try clang(allocator, io, &.{&.{ "xcrun", "clang", counted_apart, dump_o, tools.runtime, "-o", b.out }})
        else
            try runZig(allocator, io, &.{ &.{ b.zig, "build-exe" }, b.flags, &.{ "--cache-dir", b.cache, counted_apart, dump_o, tools.runtime, try allocPrint(allocator, "-femit-bin={s}", .{b.out}) } });
        b.seal(allocator, io, b.out);
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
    try clang(allocator, io, &.{ &.{ b.zig, "cc", "-target", target, "-c", "-O2" }, position, &.{ none_c, "-o", none_o } });
    const optimized = try std.fs.path.join(allocator, &.{ work, "optimized.o" });
    const r = try run(allocator, io, try std.mem.concat(allocator, []const u8, &.{ cc, &.{ try allocPrint(allocator, "-fprofile-use={s}", .{merged}), bitcode, "-o", optimized } }), true);
    if (r.code != 0) {
        std.debug.print("{s}", .{r.out});
        std.process.exit(r.code);
    }
    stale(r.out, merged);
    const optimized_apart = try apartFrom(allocator, io, b, optimized);
    const libc: []const []const u8 = if (mac) &.{"-lc"} else &.{};
    try runZig(allocator, io, &.{ &.{ b.zig, "build-exe" }, b.flags, &.{ "--cache-dir", b.cache, optimized_apart, none_o }, libc, b.link, &.{try allocPrint(allocator, "-femit-bin={s}", .{b.out})} });
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

/// Run the Zig command `argv`, which writes the program's bitcode and
/// runs no pass of LLVM's. LLVM names on stderr each pass it leaves out,
/// a line for every function and pass (77 MB for a program of 200,000
/// lines), so nothing Zig says is read while it succeeds. When it
/// fails it runs again with what it says kept in `log`, and its own
/// lines of that are shown before `rig` ends with its status.
fn writeBitcode(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, log: []const u8) !void {
    for ([_]bool{ false, true }) |keep| {
        const cwd = std.Io.Dir.cwd();
        const file = if (keep) cwd.createFile(io, log, .{}) catch |err| fail("cannot write `{s}`: {s}", .{ log, @errorName(err) }) else null;
        defer if (file) |f| f.close(io);
        var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .inherit, .stderr = if (file) |f| .{ .file = f } else .ignore }) catch |err|
            fail("cannot run `{s}`: {s}", .{ argv[0], @errorName(err) });
        const code: u8 = switch (try child.wait(io)) {
            .exited => |c| c,
            else => 255,
        };
        if (code == 0) return;
        if (!keep) continue;
        const said = cwd.readFileAlloc(io, log, allocator, .unlimited) catch "";
        var lines = std.mem.splitScalar(u8, said, '\n');
        while (lines.next()) |line| {
            if (line.len > 0 and !std.mem.startsWith(u8, line, "BISECT: ")) std.debug.print("{s}\n", .{line});
        }
        std.process.exit(code);
    }
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
