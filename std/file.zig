//! `std.file`: reading a whole file into a `String` the runtime's
//! allocator owns, so the leak checker and the sanitizer see it, writing
//! one, open files, and what is at a path. Every call that reaches the
//! file system runs on the blocking pool (`pool`), so only the task
//! making it waits, and is a fallible waiting point.

const std = @import("std");
const rig = @import("../runtime.zig");
const posix = std.posix;
const sys = posix.system;

/// `std.file.FileError`, which the emitter names
/// `error.@"std.file.FileError.name"`.
pub const FileError = error{
    @"std.file.FileError.not_found",
    @"std.file.FileError.exists",
    @"std.file.FileError.denied",
    @"std.file.FileError.not_directory",
    @"std.file.FileError.is_directory",
    @"std.file.FileError.not_empty",
    @"std.file.FileError.failed",
};
pub const Error = rig.Stop || FileError;

const not_found = error.@"std.file.FileError.not_found";

/// Run `f` on the blocking pool as a fallible waiting point: a cancel of
/// the task, or its deadline, ends the wait with a `task.Stop` while `f`
/// runs on to its end and its result is dropped (`rig.blockingStop`).
/// So `args` hold nothing the task may free meanwhile: paths and bytes,
/// which the pool copies, and plain values; a result that owns something
/// (a String, a descriptor, `Fd`) is freed by its drop.
fn pool(comptime T: type, comptime f: anytype, args: anytype) Error!T {
    return try (try rig.blockingStop(f, args));
}

/// A descriptor a pool call opened or was given, closed when dropped, as
/// a call whose task stopped waiting drops its result.
const Fd = struct {
    fd: i32,

    pub fn __rig_drop(self: *Fd) void {
        _ = sys.close(self.fd);
    }
};

/// A descriptor of the same open file as `fd`, for a pool call to own:
/// the task may close its own while the call runs on.
fn dupFd(fd: i64) FileError!Fd {
    while (true) {
        const rc = sys.fcntl(@intCast(fd), posix.F.DUPFD_CLOEXEC, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => return .{ .fd = @intCast(rc) },
            .INTR => {},
            else => |e| return errnoFailure(e),
        }
    }
}

/// Fail when the task is canceled or past its deadline, without
/// yielding: before a descriptor is duplicated for a pool call, so a
/// stopped task makes none.
fn stopped() rig.Stop!void {
    const t = rig.task();
    if (t.control) |c| if (c.canceled.load(.seq_cst)) return error.@"std.task.Stop.canceled";
    if (t.deadline) |d| if (rig.sched.nowNs() >= d) return error.@"std.task.Stop.timeout";
}

/// The FileError for a failure of Zig's, or the FileError itself.
fn failure(err: anyerror) FileError {
    if (std.mem.startsWith(u8, @errorName(err), "std.file.FileError.")) return @errorCast(err);
    return switch (err) {
        error.FileNotFound => not_found,
        error.PathAlreadyExists => error.@"std.file.FileError.exists",
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => error.@"std.file.FileError.denied",
        error.NotDir => error.@"std.file.FileError.not_directory",
        error.IsDir => error.@"std.file.FileError.is_directory",
        error.DirNotEmpty => error.@"std.file.FileError.not_empty",
        else => error.@"std.file.FileError.failed",
    };
}

/// The FileError for a failed system call's `errno`.
fn errnoFailure(e: posix.E) FileError {
    return switch (e) {
        .NOENT => not_found,
        .EXIST => error.@"std.file.FileError.exists",
        .ACCES, .PERM, .ROFS => error.@"std.file.FileError.denied",
        .NOTDIR => error.@"std.file.FileError.not_directory",
        .ISDIR => error.@"std.file.FileError.is_directory",
        .NOTEMPTY => error.@"std.file.FileError.not_empty",
        else => error.@"std.file.FileError.failed",
    };
}

/// Nothing for a failure that means nothing is at the path: nothing at
/// it, or a file on the way to it, which some systems report as one and
/// some as the other. The error for any other failure.
fn absent(err: anyerror) FileError!void {
    const e = failure(err);
    if (e == not_found or e == error.@"std.file.FileError.not_directory") return;
    return e;
}

// -----------------------------------------------------------------------------
// Whole files
// -----------------------------------------------------------------------------

/// The file at `path` in a String whose buffer holds exactly its bytes,
/// or null when nothing is there. A regular file's size sizes the
/// buffer; a file that grows while it is read, or one that reports no
/// size (a pipe, a device), is read to its end and the buffer trimmed.
pub fn read(path: []const u8) Error!?rig.String {
    return pool(?rig.String, readHere, .{path});
}

fn readHere(path: []const u8) FileError!?rig.String {
    const io = rig.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false }) catch |err| {
        try absent(err);
        return null;
    };
    defer file.close(io);
    const gpa = rig.defaultAllocator();
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    const size = std.math.cast(usize, file.length(io) catch |err| return failure(err)) orelse rig.oom();
    list.ensureTotalCapacityPrecise(gpa, size) catch rig.oom();
    // Read into the spare capacity; once it is full, into `probe`, which
    // finds the end of a regular file without growing the buffer.
    var probe: [4096]u8 = undefined;
    while (true) {
        const spare = list.unusedCapacitySlice();
        const into = if (spare.len > 0) spare else &probe;
        const n = file.readStreaming(io, &.{into}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return failure(err),
        };
        if (spare.len > 0) list.items.len += n else list.appendSlice(gpa, probe[0..n]) catch rig.oom();
    }
    if (list.capacity != list.items.len) list.shrinkAndFreePrecise(gpa, list.items.len) catch rig.oom();
    return .{ .list = list };
}

/// Write `data` as the whole file at `path`, creating it or emptying it
/// first, or at its end (`at_end`), and making each missing directory
/// on the way to it when `parents`.
pub fn write_file(path: []const u8, data: []const u8, at_end: bool, parents: bool) Error!void {
    return pool(void, writeHere, .{ path, data, at_end, parents });
}

fn writeHere(path: []const u8, data: []const u8, at_end: bool, parents: bool) FileError!void {
    const fd = try openMaking(path, if (at_end) .append else .truncate, parents);
    defer _ = sys.close(fd);
    try writeAll(fd, data);
}

/// Move what is at `from` to `to`.
pub fn rename(from: []const u8, to: []const u8) Error!void {
    return pool(void, renameHere, .{ from, to });
}

fn renameHere(from: []const u8, to: []const u8) FileError!void {
    const cwd = std.Io.Dir.cwd();
    std.Io.Dir.rename(cwd, from, cwd, to, rig.io()) catch |err| return failure(err);
}

/// Make the directory `path`, and each missing one on the way to it when
/// `parents`. A directory there already is fine.
pub fn make_dir(path: []const u8, parents: bool) Error!void {
    return pool(void, mkdirHere, .{ path, parents });
}

fn mkdirHere(path: []const u8, parents: bool) FileError!void {
    if (!parents) {
        std.Io.Dir.cwd().createDir(rig.io(), path, .default_dir) catch |err| return switch (failure(err)) {
            error.@"std.file.FileError.exists" => if (isFile(path)) error.@"std.file.FileError.exists" else {},
            else => |e| e,
        };
        return;
    }
    std.Io.Dir.cwd().createDirPath(rig.io(), path) catch |err| return switch (failure(err)) {
        // A file where a directory is wanted is something there already.
        error.@"std.file.FileError.not_directory" => if (isFile(path)) error.@"std.file.FileError.exists" else error.@"std.file.FileError.not_directory",
        else => |e| e,
    };
}

/// Whether anything is at `path`, links followed: a link that names
/// nothing is not. Any failure but "nothing there" is an error.
pub fn exists_at(path: []const u8) Error!bool {
    return pool(bool, existsHere, .{path});
}

fn existsHere(path: []const u8) FileError!bool {
    _ = std.Io.Dir.cwd().statFile(rig.io(), path, .{}) catch |err| {
        try absent(err);
        return false;
    };
    return true;
}

/// Whether a file, or anything but a directory, is at `path`.
fn isFile(path: []const u8) bool {
    const s = std.Io.Dir.cwd().statFile(rig.io(), path, .{}) catch return false;
    return s.kind != .directory;
}

/// Remove the file or empty directory at `path`: false when nothing was
/// there.
pub fn remove(path: []const u8) Error!bool {
    return pool(bool, removeHere, .{path});
}

fn removeHere(path: []const u8) FileError!bool {
    var buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    const z = try terminated(path, &buf);
    const unlinked = posix.errno(sys.unlink(z));
    if (unlinked == .SUCCESS) return true;
    if (unlinked == .NOENT) return false;
    // A directory, which `unlink` will not remove (EISDIR on Linux,
    // EPERM on macOS), or `unlink`'s own failure.
    const removed = posix.errno(sys.rmdir(z));
    return switch (removed) {
        .SUCCESS => true,
        .NOENT => false,
        .NOTDIR => errnoFailure(unlinked),
        else => errnoFailure(removed),
    };
}

/// The absolute path `path` names, links resolved, or null when nothing
/// is there.
pub fn realpath(path: []const u8) Error!?rig.String {
    return pool(?rig.String, realpathHere, .{path});
}

fn realpathHere(path: []const u8) FileError!?rig.String {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(rig.io(), path, &buf) catch |err| {
        try absent(err);
        return null;
    };
    return fresh(buf[0..n]);
}

// -----------------------------------------------------------------------------
// What is at a path
// -----------------------------------------------------------------------------

/// `stat`'s answer onto `info` (std/file.rig), or false when nothing is
/// at `path`.
pub fn stat_into(path: []const u8, info: *rig.List(i64)) Error!bool {
    const got = (try pool(?[4]i64, statHere, .{path})) orelse return false;
    for (got) |n| info.push(n);
    return true;
}

fn statHere(path: []const u8) FileError!?[4]i64 {
    const io = rig.io();
    const cwd = std.Io.Dir.cwd();
    const here = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
        try absent(err);
        return null;
    };
    var s = here;
    if (here.kind == .sym_link) {
        s = cwd.statFile(io, path, .{}) catch |err| blk: {
            // A link that names nothing.
            try absent(err);
            var broken = here;
            broken.kind = .unknown;
            broken.size = 0;
            break :blk broken;
        };
    }
    return .{
        kindCode(s.kind),
        @intFromBool(here.kind == .sym_link),
        @intCast(@min(s.size, std.math.maxInt(i64))),
        @intCast(std.math.clamp(s.mtime.nanoseconds, std.math.minInt(i64), std.math.maxInt(i64))),
    };
}

fn kindCode(kind: std.Io.File.Kind) i64 {
    return switch (kind) {
        .file => 0,
        .directory => 1,
        else => 2,
    };
}

/// The entries of the directory at `path`, last name first, onto `names`,
/// and each one's kind, plus 4 for a link, onto `codes`; false when
/// nothing is at `path`.
pub fn dir_entries(path: []const u8, names: *rig.List(rig.String), codes: *rig.List(i64)) Error!bool {
    var got = (try pool(?Entries, entriesHere, .{path})) orelse return false;
    std.mem.swap(rig.List(rig.String), names, &got.names);
    std.mem.swap(rig.List(i64), codes, &got.codes);
    rig.dropElement(Entries, &got);
    return true;
}

/// A directory's entries as `dir_entries` gives them, which a pool call
/// owns until it returns.
const Entries = struct {
    names: rig.List(rig.String) = .empty,
    codes: rig.List(i64) = .empty,
};

fn entriesHere(path: []const u8) FileError!?Entries {
    const io = rig.io();
    const gpa = std.heap.smp_allocator;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        // A file at the path, or on the way to it, is not a directory.
        if (failure(err) != not_found) return failure(err);
        return null;
    };
    defer dir.close(io);
    const Found = struct { name: []u8, code: i64 };
    var found: std.ArrayList(Found) = .empty;
    defer {
        for (found.items) |f| gpa.free(f.name);
        found.deinit(gpa);
    }
    var it = dir.iterate();
    while (it.next(io) catch |err| return failure(err)) |entry| {
        var kind = entry.kind;
        var link = kind == .sym_link;
        // A link's kind is what it names; a kind the directory does not
        // record is looked up.
        if (link or kind == .unknown) {
            if (dir.statFile(io, entry.name, .{ .follow_symlinks = false })) |here| {
                link = here.kind == .sym_link;
                kind = here.kind;
                if (link) kind = if (dir.statFile(io, entry.name, .{})) |target| target.kind else |_| .unknown;
            } else |_| kind = .unknown;
        }
        const name = gpa.dupe(u8, entry.name) catch rig.oom();
        found.append(gpa, .{ .name = name, .code = kindCode(kind) + @as(i64, if (link) 4 else 0) }) catch rig.oom();
    }
    std.mem.sort(Found, found.items, {}, struct {
        fn later(_: void, a: Found, b: Found) bool {
            return std.mem.order(u8, a.name, b.name) == .gt;
        }
    }.later);
    var out: Entries = .{};
    for (found.items) |f| {
        out.names.push(fresh(f.name));
        out.codes.push(f.code);
    }
    return out;
}

// -----------------------------------------------------------------------------
// Open files
// -----------------------------------------------------------------------------

/// A descriptor of the file at `path` open to read, or null when nothing
/// is there.
pub fn open_fd(path: []const u8) Error!?i64 {
    const got = (try pool(?Fd, openHere, .{path})) orelse return null;
    return got.fd;
}

fn openHere(path: []const u8) FileError!?Fd {
    var buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    const fd = openAt(try terminated(path, &buf), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch |err| {
        try absent(err);
        return null;
    };
    return .{ .fd = fd };
}

/// A descriptor of the file at `path`, created or emptied, open to
/// write, each missing directory on the way to it made when `parents`.
pub fn create_fd(path: []const u8, parents: bool) Error!i64 {
    return (try pool(Fd, createHere, .{ path, parents })).fd;
}

fn createHere(path: []const u8, parents: bool) FileError!Fd {
    return .{ .fd = try openMaking(path, .truncate, parents) };
}

/// Open `path` to write, creating it when it is not there, and each
/// missing directory on the way to it when `parents`: emptied, or to
/// write at its end.
fn openMaking(path: []const u8, how: enum { truncate, append }, parents: bool) FileError!i32 {
    var buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    const z = try terminated(path, &buf);
    var flags: posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true };
    if (how == .truncate) flags.TRUNC = true else flags.APPEND = true;
    return openAt(z, flags) catch |err| {
        if (err != not_found or !parents) return err;
        // A directory on the way is missing: make them all, then try once
        // more.
        const parent = std.fs.path.dirname(path) orelse return err;
        std.Io.Dir.cwd().createDirPath(rig.io(), parent) catch |e| return failure(e);
        return openAt(z, flags);
    };
}

fn openAt(path: [*:0]const u8, flags: posix.O) FileError!i32 {
    while (true) {
        const rc = sys.openat(posix.AT.FDCWD, path, flags, @as(posix.mode_t, 0o666));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => {},
            else => |e| return errnoFailure(e),
        }
    }
}

/// `path` with a 0 after it, in `buf`.
fn terminated(path: []const u8, buf: *[std.Io.Dir.max_path_bytes:0]u8) FileError![*:0]const u8 {
    if (path.len >= buf.len or std.mem.findScalar(u8, path, 0) != null) return error.@"std.file.FileError.failed";
    if (path.len == 0) return not_found;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

pub fn read_from(fd: i64, into: *rig.String, max: i64) Error!i64 {
    const want: usize = @intCast(@max(max, 0));
    if (want == 0) return 0;
    try stopped();
    var got = try pool(rig.String, readOwned, .{ try dupFd(fd), want });
    defer rig.dropElement(rig.String, &got);
    into.list.appendSlice(rig.defaultAllocator(), got.list.items) catch rig.oom();
    return @intCast(got.list.items.len);
}

/// Up to `want` bytes read from `fd`, which it closes, in a fresh String.
fn readOwned(fd: Fd, want: usize) FileError!rig.String {
    var own = fd;
    defer own.__rig_drop();
    var s: rig.String = .empty;
    errdefer rig.dropElement(rig.String, &s);
    s.list.ensureTotalCapacityPrecise(rig.defaultAllocator(), want) catch rig.oom();
    s.list.items.len = try readSome(own.fd, s.list.unusedCapacitySlice()[0..want]);
    return s;
}

fn readSome(fd: i32, dest: []u8) FileError!usize {
    while (true) {
        const rc = sys.read(fd, dest.ptr, dest.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => {},
            else => |e| return errnoFailure(e),
        }
    }
}

pub fn write_to(fd: i64, bytes: []const u8) Error!void {
    try stopped();
    return pool(void, writeOwned, .{ try dupFd(fd), bytes });
}

/// Write all of `bytes` to `fd`, which it closes.
fn writeOwned(fd: Fd, bytes: []const u8) FileError!void {
    var own = fd;
    defer own.__rig_drop();
    try writeAll(own.fd, bytes);
}

fn writeAll(fd: i32, bytes: []const u8) FileError!void {
    var at: usize = 0;
    while (at < bytes.len) {
        const rc = sys.write(fd, bytes[at..].ptr, bytes.len - at);
        switch (posix.errno(rc)) {
            .SUCCESS => at += @intCast(rc),
            .INTR => {},
            else => |e| return errnoFailure(e),
        }
    }
}

pub fn close(fd: i64) void {
    _ = sys.close(@intCast(fd));
}

/// A fresh String of `bytes`.
fn fresh(bytes: []const u8) rig.String {
    var s: rig.String = .empty;
    s.list.appendSlice(rig.defaultAllocator(), bytes) catch rig.oom();
    return s;
}
