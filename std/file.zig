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

/// Run `f` on the blocking pool, once the task is neither canceled nor
/// past its deadline.
fn pool(comptime T: type, comptime f: anytype, args: anytype) Error!T {
    try rig.taskCheck();
    return rig.blocking(f, args);
}

/// The FileError for a failure of Zig's.
fn failure(err: anyerror) FileError {
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

/// Null for `not_found`, the error for any other failure.
fn absent(err: anyerror) FileError!void {
    const e = failure(err);
    if (e == not_found) return;
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

/// Write `data` as the whole file at `path`, creating it or truncating
/// it, and making each missing directory on the way to it.
pub fn write(path: []const u8, data: []const u8) Error!void {
    return pool(void, writeHere, .{ path, data, false });
}

/// Write `data` at the end of the file at `path`, creating it, and each
/// missing directory on the way to it, when it is not there.
pub fn append(path: []const u8, data: []const u8) Error!void {
    return pool(void, writeHere, .{ path, data, true });
}

fn writeHere(path: []const u8, data: []const u8, at_end: bool) FileError!void {
    const fd = try openMaking(path, if (at_end) .append else .truncate);
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

/// Make the directory `path` and each missing one on the way to it.
pub fn mkdir(path: []const u8) Error!void {
    return pool(void, mkdirHere, .{path});
}

fn mkdirHere(path: []const u8) FileError!void {
    std.Io.Dir.cwd().createDirPath(rig.io(), path) catch |err| return switch (failure(err)) {
        // A file where a directory is wanted is something there already.
        error.@"std.file.FileError.not_directory" => if (isFile(path)) error.@"std.file.FileError.exists" else error.@"std.file.FileError.not_directory",
        else => |e| e,
    };
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
    return pool(bool, statHere, .{ path, info });
}

fn statHere(path: []const u8, info: *rig.List(i64)) FileError!bool {
    const io = rig.io();
    const cwd = std.Io.Dir.cwd();
    const here = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
        try absent(err);
        return false;
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
    info.push(kindCode(s.kind));
    info.push(@intFromBool(here.kind == .sym_link));
    info.push(@intCast(@min(s.size, std.math.maxInt(i64))));
    info.push(@intCast(std.math.clamp(s.mtime.nanoseconds, std.math.minInt(i64), std.math.maxInt(i64))));
    return true;
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
    return pool(bool, entriesHere, .{ path, names, codes });
}

fn entriesHere(path: []const u8, names: *rig.List(rig.String), codes: *rig.List(i64)) FileError!bool {
    const io = rig.io();
    const gpa = std.heap.smp_allocator;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        try absent(err);
        return false;
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
    for (found.items) |f| {
        names.push(fresh(f.name));
        codes.push(f.code);
    }
    return true;
}

// -----------------------------------------------------------------------------
// Open files
// -----------------------------------------------------------------------------

/// A descriptor of the file at `path` open to read, or null when nothing
/// is there.
pub fn open_fd(path: []const u8) Error!?i64 {
    return pool(?i64, openHere, .{path});
}

fn openHere(path: []const u8) FileError!?i64 {
    var buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    const fd = openAt(try terminated(path, &buf), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) catch |err| {
        if (err == not_found) return null;
        return err;
    };
    return fd;
}

/// A descriptor of the file at `path`, created or emptied, open to
/// write, each missing directory on the way to it made.
pub fn create_fd(path: []const u8) Error!i64 {
    return pool(i64, createHere, .{path});
}

fn createHere(path: []const u8) FileError!i64 {
    return try openMaking(path, .truncate);
}

/// Open `path` to write, creating it, and each missing directory on the
/// way to it, when it is not there: emptied, or to write at its end.
fn openMaking(path: []const u8, how: enum { truncate, append }) FileError!i32 {
    var buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    const z = try terminated(path, &buf);
    var flags: posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true };
    if (how == .truncate) flags.TRUNC = true else flags.APPEND = true;
    return openAt(z, flags) catch |err| {
        if (err != not_found) return err;
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
    into.list.ensureUnusedCapacity(rig.defaultAllocator(), want) catch rig.oom();
    const n = try pool(usize, readSome, .{ @as(i32, @intCast(fd)), into.list.unusedCapacitySlice()[0..want] });
    into.list.items.len += n;
    return @intCast(n);
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
    return pool(void, writeAll, .{ @as(i32, @intCast(fd)), bytes });
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
