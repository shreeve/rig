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
//! A program built to be preempted keeps its own code in a section of
//! its own, `rig_text`, the only code a signal stops a task in
//! (`sched.inCode`). BOLT would move the program's functions and the
//! runtime's into one new `.text`, side by side, so it lays out only the
//! program's (`-funcs-file-no-regex`), those the profile names; the
//! runtime's stay where the linker put them. Then `seal` writes where
//! the program's code now lies into the executable, which the runtime
//! reads as it starts (`sched.CodeWord`), and fails the build if any
//! section holds functions of both.
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
    const funcs = try std.fmt.allocPrint(allocator, "{s}.funcs", .{exe});
    const cwd = std.Io.Dir.cwd();
    defer {
        cwd.deleteFile(io, data) catch {};
        cwd.deleteFile(io, laid) catch {};
        cwd.deleteFile(io, funcs) catch {};
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
    // The program's own functions, in a program built to be preempted:
    // only those BOLT lays out.
    const linked = cwd.readFileAlloc(io, exe, allocator, .limited(1 << 32)) catch |err| fail("cannot read `{s}`: {s}", .{ exe, @errorName(err) });
    const names = functionNames(allocator, linked) catch |err| fail("cannot read the functions of `{s}`: {s}", .{ exe, @errorName(err) });
    var select: []const []const u8 = &.{};
    if (names) |*n| {
        const profile_text = cwd.readFileAlloc(io, fdata, allocator, .limited(1 << 32)) catch |err| fail("cannot read BOLT's profile `{s}`: {s}", .{ fdata, @errorName(err) });
        const list = try profiled(allocator, n, profile_text);
        if (list.len == 0) {
            std.debug.print("warning: BOLT's profile names none of the program's own functions: `{s}` is left as linked\n", .{exe});
            return;
        }
        cwd.writeFile(io, .{ .sub_path = funcs, .data = list }) catch |err| fail("cannot write `{s}`: {s}", .{ funcs, @errorName(err) });
        const flag = try allocator.alloc([]const u8, 1);
        flag[0] = try std.fmt.allocPrint(allocator, "-funcs-file-no-regex={s}", .{funcs});
        select = flag;
    }
    const args = try std.mem.concat(allocator, []const u8, &.{ &.{ tools.llvm_bolt, exe, "-o", laid, try std.fmt.allocPrint(allocator, "-data={s}", .{fdata}), "-reorder-blocks=ext-tsp", "-reorder-functions=cdsort", "-split-functions", "-split-all-cold", "-icf=1", "-infer-stale-profile" }, select });
    const r = try run(allocator, io, args, true);
    if (r.code != 0) fail("llvm-bolt could not lay out `{s}`:\n{s}", .{ exe, r.out });
    if (std.mem.indexOf(u8, r.out, more_samples)) |at| {
        const rest = r.out[at + more_samples.len ..];
        std.debug.print("warning: BOLT wants {s} the samples the workload gave: run it longer, or more times\n", .{rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len]});
    }
    if (names) |*n| {
        const bytes = cwd.readFileAlloc(io, laid, allocator, .limited(1 << 32)) catch |err| fail("cannot read `{s}`: {s}", .{ laid, @errorName(err) });
        seal(allocator, n, bytes) catch |err| fail("cannot find where BOLT put the program's own code in `{s}`: {s}", .{ exe, sealError(err) });
        cwd.writeFile(io, .{ .sub_path = laid, .data = bytes }) catch |err| fail("cannot write `{s}`: {s}", .{ laid, @errorName(err) });
    }
    cwd.rename(laid, cwd, exe, io) catch |err| fail("cannot replace `{s}`: {s}", .{ exe, @errorName(err) });
}

/// The ELF section of the program's own code (`sched.preempt_section`).
const code_section = "rig_text";

/// The functions of a linked executable, by name: the program's own,
/// those of `code_section`, and every other, which may be the runtime's.
/// A name in both sets is neither's.
const Names = struct {
    program: std.StringHashMapUnmanaged(void) = .empty,
    other: std.StringHashMapUnmanaged(void) = .empty,

    const Kind = enum { program, other, neither };

    /// Whose function a symbol of the laid-out executable names: BOLT
    /// keeps each function's name, and names the parts it makes after
    /// it (`f.cold.0`, `f.warm`, a folded copy's `f.icf.0`, and a local
    /// function's `f/1`). A name the linked executable never had is
    /// counted as another's: nothing vouches for it.
    fn kind(n: *const Names, symbol: []const u8) Kind {
        var name = symbol;
        while (true) {
            const p = n.program.contains(name);
            const o = n.other.contains(name);
            if (p and o) return .neither;
            if (p) return .program;
            if (o) return .other;
            name = boltBase(name) orelse return .other;
        }
    }
};

/// `name` without the last part BOLT added to it, or null.
fn boltBase(name: []const u8) ?[]const u8 {
    for ([_][]const u8{ ".icf.0", ".warm", ".cold" }) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) return name[0 .. name.len - suffix.len];
    }
    // `.cold.N`
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        const digits = name[dot + 1 ..];
        if (digits.len > 0 and std.mem.endsWith(u8, name[0..dot], ".cold") and for (digits) |c| {
            if (!std.ascii.isDigit(c)) break false;
        } else true) return name[0 .. dot - ".cold".len];
    }
    if (std.mem.indexOfScalar(u8, name, '/')) |slash| return name[0..slash];
    return null;
}

/// The functions of the linked executable `bytes`; null when it has no
/// `code_section`: a program not built to be preempted, which BOLT lays
/// out whole.
fn functionNames(allocator: std.mem.Allocator, bytes: []const u8) !?Names {
    const e = Elf.read(bytes) orelse return error.NotElf;
    const code = e.find(code_section) orelse return null;
    var names: Names = .{};
    var it = e.symbols() orelse return error.NoSymbols;
    while (it.next()) |s| {
        if (!s.isFunction()) continue;
        try (if (s.shndx == code) &names.program else &names.other).put(allocator, s.name, {});
    }
    return names;
}

/// The lines of BOLT's list of functions to lay out
/// (`-funcs-file-no-regex`): each function the profile names, by the name
/// it gives, that the linker put in `code_section` and no other function
/// shares. The profile names a local function `f/1`, as BOLT does. Read
/// are perf2bolt's lines (`1 f/1 1a 1 g 2f 0 15`, branches, and `1 f/1
/// 1a 15`, samples) and a YAML profile's `name: f/1`; a function named
/// otherwise stays where the linker put it, in the program's section.
fn profiled(allocator: std.mem.Allocator, names: *const Names, text: []const u8) ![]const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        var found: [2]?[]const u8 = .{ null, null };
        if (std.mem.startsWith(u8, line, "name:") or std.mem.startsWith(u8, line, "- name:")) {
            found[0] = std.mem.trim(u8, line[std.mem.indexOfScalar(u8, line, ':').? + 1 ..], " \t'\"");
        } else {
            var tokens: [8][]const u8 = undefined;
            var count: usize = 0;
            var it = std.mem.tokenizeAny(u8, line, " \t");
            while (it.next()) |t| : (count += 1) {
                if (count == tokens.len) break;
                tokens[count] = t;
            }
            for (0..2) |k| {
                const i = 3 * k;
                if (i + 1 < count and std.mem.eql(u8, tokens[i], "1")) found[k] = tokens[i + 1];
            }
        }
        for (found) |f| {
            const name = f orelse continue;
            const base = name[0 .. std.mem.indexOfScalar(u8, name, '/') orelse name.len];
            if (!names.program.contains(base) or names.other.contains(base)) continue;
            const gop = try seen.getOrPut(allocator, name);
            if (gop.found_existing) continue;
            try out.appendSlice(allocator, name);
            try out.append(allocator, '\n');
        }
    }
    return out.items;
}

/// Write into the laid-out executable `bytes` where the program's own
/// code lies (`sched.CodeWord`): each section of code all of whose
/// functions are the program's, BOLT's new ones and the program's
/// section with the functions BOLT left there. A section that holds both
/// the program's functions and another's fails, since a signal stops a
/// task anywhere in the program's code, and the runtime's may hold its
/// worker; so does a word that is missing, or ranges more than it holds.
fn seal(allocator: std.mem.Allocator, names: *const Names, bytes: []u8) !void {
    const e = Elf.read(bytes) orelse return error.NotElf;
    const Fn = struct { at: u64, kind: Names.Kind };
    var fns: std.ArrayList(Fn) = .empty;
    var it = e.symbols() orelse return error.NoSymbols;
    while (it.next()) |s| {
        if (s.isFunction()) try fns.append(allocator, .{ .at = s.value, .kind = names.kind(s.name) });
    }
    var ranges: std.ArrayList([2]u64) = .empty;
    for (0..e.shnum) |k| {
        if (!e.isCode(k)) continue;
        const lo = e.u64Of(k, 16);
        const hi = lo + e.u64Of(k, 32);
        var program = false;
        var other = false;
        for (fns.items) |f| {
            if (f.at < lo or f.at >= hi) continue;
            switch (f.kind) {
                .program => program = true,
                .other => other = true,
                .neither => {},
            }
        }
        if (program and other) return error.MixedSection;
        if (program) try ranges.append(allocator, .{ lo, hi });
    }
    if (ranges.items.len == 0) return error.NoProgramCode;
    std.mem.sort([2]u64, ranges.items, {}, struct {
        fn less(_: void, a: [2]u64, b: [2]u64) bool {
            return a[0] < b[0];
        }
    }.less);
    // Merge sections that overlap or touch: BOLT's `.bolt.text` spans
    // the new sections it adds.
    var merged: std.ArrayList([2]u64) = .empty;
    for (ranges.items) |r| {
        if (merged.items.len > 0 and r[0] <= merged.items[merged.items.len - 1][1]) {
            const last = &merged.items[merged.items.len - 1];
            last[1] = @max(last[1], r[1]);
        } else try merged.append(allocator, r);
    }
    if (merged.items.len > max_code_ranges) return error.TooManyRanges;
    for (fns.items) |f| {
        if (f.kind != .other) continue;
        for (merged.items) |r| if (f.at >= r[0] and f.at < r[1]) return error.MixedSection;
    }
    var at: usize = 0;
    var words: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, at, code_magic)) |i| : (at = i + code_magic.len) {
        const self = e.addressOf(i) orelse return error.NoCodeWord;
        const word = bytes[i + code_magic.len ..];
        if (word.len < 16 + 16 * max_code_ranges) return error.NoCodeWord;
        std.mem.writeInt(u64, word[0..8], merged.items.len, .little);
        std.mem.writeInt(u64, word[8..16], self, .little);
        for (0..max_code_ranges) |r| {
            const range: [2]u64 = if (r < merged.items.len) merged.items[r] else .{ 0, 0 };
            std.mem.writeInt(u64, word[16 + 16 * r ..][0..8], range[0], .little);
            std.mem.writeInt(u64, word[24 + 16 * r ..][0..8], range[1], .little);
        }
        words += 1;
    }
    if (words == 0) return error.NoCodeWord;
}

/// The word the runtime reads the program's code ranges from, and how
/// many it holds (`sched.CodeWord`, `sched.max_code_ranges`).
const code_magic = "rig-code-ranges!";
const max_code_ranges = 8;

fn sealError(err: anyerror) []const u8 {
    return switch (err) {
        error.MixedSection => "a section of code holds both the program's functions and the runtime's",
        error.NoProgramCode => "no section of code holds the program's functions",
        error.TooManyRanges => "the program's code lies in more sections than the runtime reads",
        error.NoCodeWord => "the executable has no word for the ranges of the program's code",
        else => @errorName(err),
    };
}

/// The few parts of a little-endian ELF64 file `seal` reads.
const Elf = struct {
    bytes: []const u8,
    shoff: usize,
    shentsize: usize,
    shnum: usize,
    names: []const u8,

    fn read(bytes: []const u8) ?Elf {
        if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..4], "\x7fELF") or bytes[4] != 2 or bytes[5] != 1) return null;
        const shoff: usize = @intCast(readInt(u64, bytes, 40));
        const shentsize: usize = readInt(u16, bytes, 58);
        const shnum: usize = readInt(u16, bytes, 60);
        const shstrndx: usize = readInt(u16, bytes, 62);
        if (shentsize < 64 or shstrndx >= shnum or shoff > bytes.len or shnum * shentsize > bytes.len - shoff) return null;
        var e: Elf = .{ .bytes = bytes, .shoff = shoff, .shentsize = shentsize, .shnum = shnum, .names = "" };
        e.names = e.contents(shstrndx) orelse return null;
        return e;
    }

    fn u32Of(e: Elf, k: usize, field: usize) u32 {
        return readInt(u32, e.bytes, e.shoff + k * e.shentsize + field);
    }

    fn u64Of(e: Elf, k: usize, field: usize) u64 {
        return readInt(u64, e.bytes, e.shoff + k * e.shentsize + field);
    }

    fn contents(e: Elf, k: usize) ?[]const u8 {
        const at = e.u64Of(k, 24);
        const len = e.u64Of(k, 32);
        if (at > e.bytes.len or len > e.bytes.len - at) return null;
        return e.bytes[@intCast(at)..][0..@intCast(len)];
    }

    fn find(e: Elf, name: []const u8) ?usize {
        for (0..e.shnum) |k| {
            const n = cString(e.names, e.u32Of(k, 0)) orelse continue;
            if (std.mem.eql(u8, n, name)) return k;
        }
        return null;
    }

    /// Whether section `k` is code in the loaded image.
    fn isCode(e: Elf, k: usize) bool {
        const flags = e.u64Of(k, 8);
        return flags & 0x6 == 0x6 and e.u32Of(k, 4) != 8 and e.u64Of(k, 32) > 0;
    }

    /// The address, as linked, of the byte at file offset `at`.
    fn addressOf(e: Elf, at: usize) ?u64 {
        for (0..e.shnum) |k| {
            if (e.u64Of(k, 8) & 0x2 == 0 or e.u32Of(k, 4) == 8) continue;
            const off = e.u64Of(k, 24);
            if (at >= off and at < off + e.u64Of(k, 32)) return e.u64Of(k, 16) + (at - off);
        }
        return null;
    }

    const Symbol = struct {
        name: []const u8,
        value: u64,
        shndx: u16,
        info: u8,

        /// A function defined in a section of the file.
        fn isFunction(s: Symbol) bool {
            return s.info & 0xf == 2 and s.shndx != 0 and s.shndx < 0xff00;
        }
    };

    const Symbols = struct {
        syms: []const u8,
        strs: []const u8,
        at: usize = 0,

        fn next(it: *Symbols) ?Symbol {
            while (it.at + 24 <= it.syms.len) {
                const e = it.at;
                it.at += 24;
                const name = cString(it.strs, readInt(u32, it.syms, e)) orelse continue;
                return .{ .name = name, .value = readInt(u64, it.syms, e + 8), .shndx = readInt(u16, it.syms, e + 6), .info = it.syms[e + 4] };
            }
            return null;
        }
    };

    /// The symbol table's entries.
    fn symbols(e: Elf) ?Symbols {
        for (0..e.shnum) |k| {
            if (e.u32Of(k, 4) != 2) continue;
            const link: usize = e.u32Of(k, 40);
            if (link >= e.shnum) return null;
            return .{ .syms = e.contents(k) orelse return null, .strs = e.contents(link) orelse return null };
        }
        return null;
    }
};

fn cString(table: []const u8, at: u32) ?[]const u8 {
    if (at >= table.len) return null;
    const rest = table[at..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, 0) orelse return null];
}

fn readInt(comptime T: type, b: []const u8, at: usize) T {
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
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

/// A little-endian ELF64 file for the tests: each section's contents
/// follow the header, then its symbol table, then the section headers.
const TestElf = struct {
    const Section = struct { name: []const u8, addr: u64, size: u64, code: bool = true, data: []const u8 = "" };
    const Sym = struct { name: []const u8, value: u64, section: u16, func: bool = true };

    fn build(allocator: std.mem.Allocator, sections: []const Section, syms: []const Sym) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendNTimes(allocator, 0, 64);
        var shstr: std.ArrayList(u8) = .empty;
        try shstr.append(allocator, 0);
        var str: std.ArrayList(u8) = .empty;
        try str.append(allocator, 0);
        const Header = struct { name: u32, type: u32, flags: u64, addr: u64, off: u64, size: u64, link: u32 };
        var headers: std.ArrayList(Header) = .empty;
        try headers.append(allocator, .{ .name = 0, .type = 0, .flags = 0, .addr = 0, .off = 0, .size = 0, .link = 0 });
        for (sections) |s| {
            const name: u32 = @intCast(shstr.items.len);
            try shstr.appendSlice(allocator, s.name);
            try shstr.append(allocator, 0);
            // Code is not read, only its place: its bytes lie past the
            // file's end, where no word is looked for.
            const off = if (s.data.len > 0) out.items.len else 1 << 40;
            if (s.data.len > 0) try out.appendSlice(allocator, s.data);
            try headers.append(allocator, .{ .name = name, .type = 1, .flags = if (s.code) 0x6 else 0x3, .addr = s.addr, .off = off, .size = if (s.data.len > 0) s.data.len else s.size, .link = 0 });
        }
        var symtab: std.ArrayList(u8) = .empty;
        try symtab.appendNTimes(allocator, 0, 24);
        for (syms) |s| {
            var e: [24]u8 = @splat(0);
            std.mem.writeInt(u32, e[0..4], @intCast(str.items.len), .little);
            try str.appendSlice(allocator, s.name);
            try str.append(allocator, 0);
            e[4] = if (s.func) 2 else 0;
            std.mem.writeInt(u16, e[6..8], s.section, .little);
            std.mem.writeInt(u64, e[8..16], s.value, .little);
            try symtab.appendSlice(allocator, &e);
        }
        const tables = [_]struct { name: []const u8, type: u32, bytes: []const u8 }{
            .{ .name = ".symtab", .type = 2, .bytes = symtab.items },
            .{ .name = ".strtab", .type = 3, .bytes = str.items },
            .{ .name = ".shstrtab", .type = 3, .bytes = "" },
        };
        const first: u32 = @intCast(headers.items.len);
        for (tables, 0..) |t, i| {
            const name: u32 = @intCast(shstr.items.len);
            try shstr.appendSlice(allocator, t.name);
            try shstr.append(allocator, 0);
            const bytes = if (i == 2) shstr.items else t.bytes;
            const off = out.items.len;
            try out.appendSlice(allocator, bytes);
            try headers.append(allocator, .{ .name = name, .type = t.type, .flags = 0, .addr = 0, .off = off, .size = bytes.len, .link = if (i == 0) first + 1 else 0 });
        }
        const shoff = out.items.len;
        for (headers.items) |h| {
            var e: [64]u8 = @splat(0);
            std.mem.writeInt(u32, e[0..4], h.name, .little);
            std.mem.writeInt(u32, e[4..8], h.type, .little);
            std.mem.writeInt(u64, e[8..16], h.flags, .little);
            std.mem.writeInt(u64, e[16..24], h.addr, .little);
            std.mem.writeInt(u64, e[24..32], h.off, .little);
            std.mem.writeInt(u64, e[32..40], h.size, .little);
            std.mem.writeInt(u32, e[40..44], h.link, .little);
            try out.appendSlice(allocator, &e);
        }
        const b = out.items;
        @memcpy(b[0..4], "\x7fELF");
        b[4] = 2;
        b[5] = 1;
        std.mem.writeInt(u64, b[40..48], shoff, .little);
        std.mem.writeInt(u16, b[58..60], 64, .little);
        std.mem.writeInt(u16, b[60..62], @intCast(headers.items.len), .little);
        std.mem.writeInt(u16, b[62..64], @intCast(headers.items.len - 1), .little);
        return b;
    }

    /// The runtime's word as it is built (`sched.CodeWord`).
    fn word() [16 + 16 + 16 * max_code_ranges]u8 {
        var w: [16 + 16 + 16 * max_code_ranges]u8 = @splat(0);
        @memcpy(w[0..16], code_magic);
        return w;
    }

    fn ranges(bytes: []const u8) struct { n: u64, self: u64, at: [max_code_ranges][2]u64 } {
        const i = std.mem.indexOf(u8, bytes, code_magic).? + 16;
        var at: [max_code_ranges][2]u64 = undefined;
        for (0..max_code_ranges) |r| at[r] = .{ readInt(u64, bytes, i + 16 + 16 * r), readInt(u64, bytes, i + 24 + 16 * r) };
        return .{ .n = readInt(u64, bytes, i), .self = readInt(u64, bytes, i + 8), .at = at };
    }
};

test "the linked executable's functions: the program's are those of its section" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = TestElf.word();
    const linked = try TestElf.build(a, &.{
        .{ .name = ".text", .addr = 0x1000, .size = 0x100 },
        .{ .name = "rig_text", .addr = 0x2000, .size = 0x100 },
        .{ .name = ".data", .addr = 0x5000, .size = 0, .code = false, .data = &w },
    }, &.{
        .{ .name = "sched.wake", .value = 0x1000, .section = 1 },
        .{ .name = "main.step", .value = 0x2000, .section = 2 },
        .{ .name = "main.run", .value = 0x2040, .section = 2 },
        .{ .name = "__start_rig_text", .value = 0x2000, .section = 2, .func = false },
    });
    var names = (try functionNames(a, linked)).?;
    try std.testing.expect(names.program.contains("main.step") and names.program.contains("main.run"));
    try std.testing.expect(names.other.contains("sched.wake") and !names.program.contains("__start_rig_text"));
    try std.testing.expectEqual(Names.Kind.program, names.kind("main.step.cold.0"));
    try std.testing.expectEqual(Names.Kind.program, names.kind("main.step/1.cold.0"));
    try std.testing.expectEqual(Names.Kind.program, names.kind("main.run.icf.0"));
    try std.testing.expectEqual(Names.Kind.other, names.kind("sched.wake.cold.1"));
    try std.testing.expectEqual(Names.Kind.other, names.kind("bolt.made"));

    // As linked, the program's code is its section.
    try seal(a, &names, linked);
    const r = TestElf.ranges(linked);
    try std.testing.expectEqual(@as(u64, 1), r.n);
    try std.testing.expectEqual([2]u64{ 0x2000, 0x2100 }, r.at[0]);
    try std.testing.expectEqual(@as(u64, 0x5000), r.self);

    // A program not built to be preempted has no section of its own.
    const plain = try TestElf.build(a, &.{.{ .name = ".text", .addr = 0x1000, .size = 0x100 }}, &.{.{ .name = "main.step", .value = 0x1000, .section = 1 }});
    try std.testing.expect((try functionNames(a, plain)) == null);
}

test "BOLT lays out only the program's functions its profile names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var names: Names = .{};
    for ([_][]const u8{ "main.step", "main.run", "main.dup" }) |n| try names.program.put(a, n, {});
    for ([_][]const u8{ "sched.wake", "main.dup" }) |n| try names.other.put(a, n, {});
    const fdata =
        \\boltedcollection
        \\1 main.step/1 1a 1 sched.wake/1 2f 0 15
        \\1 sched.wake/1 4 1 main.run 10 0 3
        \\1 main.step/1 0 1 main.dup/1 0 0 2
        \\0 [unknown] 0 1 main.step/1 8 0 1
    ;
    try std.testing.expectEqualStrings("main.step/1\nmain.run\n", try profiled(a, &names, fdata));
    const yaml =
        \\---
        \\  - name:            'main.run'
        \\    fid:             3
        \\  - name:            sched.wake/1
    ;
    try std.testing.expectEqualStrings("main.run\n", try profiled(a, &names, yaml));
    try std.testing.expectEqualStrings("", try profiled(a, &names, "no_lbr cycles:u\n1 sched.wake/1 4 9\n"));
}

test "seal writes where BOLT put the program's code, and fails where it mixed it with the runtime's" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var names: Names = .{};
    for ([_][]const u8{ "main.step", "main.run", "main.left" }) |n| try names.program.put(a, n, {});
    for ([_][]const u8{ "sched.wake", "rt.alloc" }) |n| try names.other.put(a, n, {});
    const w = TestElf.word();
    // The runtime's code where the linker put it; the program's section
    // with the function BOLT left; BOLT's new code, its cold part, and
    // the section that spans them.
    const sections = [_]TestElf.Section{
        .{ .name = ".bolt.org.text", .addr = 0x1000, .size = 0x1000 },
        .{ .name = "rig_text", .addr = 0x2000, .size = 0x1000 },
        .{ .name = ".data", .addr = 0x5000, .size = 0, .code = false, .data = &w },
        .{ .name = ".text", .addr = 0x200000, .size = 0x800 },
        .{ .name = ".text.cold", .addr = 0x200800, .size = 0x100 },
        .{ .name = ".bolt.text", .addr = 0x200000, .size = 0x900 },
    };
    const laid = try TestElf.build(a, &sections, &.{
        .{ .name = "sched.wake", .value = 0x1000, .section = 1 },
        .{ .name = "rt.alloc", .value = 0x1100, .section = 1 },
        .{ .name = "main.left", .value = 0x2400, .section = 2 },
        .{ .name = "main.step", .value = 0x200000, .section = 4 },
        .{ .name = "main.run", .value = 0x200100, .section = 4 },
        .{ .name = "main.step.cold.0", .value = 0x200800, .section = 5 },
    });
    try seal(a, &names, laid);
    const r = TestElf.ranges(laid);
    try std.testing.expectEqual(@as(u64, 2), r.n);
    try std.testing.expectEqual([2]u64{ 0x2000, 0x3000 }, r.at[0]);
    try std.testing.expectEqual([2]u64{ 0x200000, 0x200900 }, r.at[1]);
    try std.testing.expectEqual([2]u64{ 0, 0 }, r.at[2]);

    // The runtime's function moved beside the program's: no ranges.
    const mixed = try TestElf.build(a, &sections, &.{
        .{ .name = "sched.wake", .value = 0x200200, .section = 4 },
        .{ .name = "main.step", .value = 0x200000, .section = 4 },
    });
    try std.testing.expectError(error.MixedSection, seal(a, &names, mixed));
    // A function nothing vouches for, beside the program's.
    const unknown = try TestElf.build(a, &sections, &.{
        .{ .name = "main.step", .value = 0x200000, .section = 4 },
        .{ .name = "__bolt_helper", .value = 0x200300, .section = 4 },
    });
    try std.testing.expectError(error.MixedSection, seal(a, &names, unknown));
    // No word to write them in.
    var no_word = sections;
    no_word[2].data = "nothing here";
    const bare = try TestElf.build(a, &no_word, &.{.{ .name = "main.step", .value = 0x200000, .section = 4 }});
    try std.testing.expectError(error.NoCodeWord, seal(a, &names, bare));
}
