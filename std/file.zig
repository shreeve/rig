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
/// or null when nothing is there. A regular file is read up to the size
/// it has when opened, with no last read to find its end: bytes another
/// writer adds meanwhile are left out, as if they came after. One that
/// reports no size (a pipe, a device, a Linux `/proc` file) is read to
/// its end and the buffer trimmed.
pub fn read(path: []const u8) Error!?rig.String {
    return pool(?rig.String, readHere, .{path});
}

fn readHere(path: []const u8) FileError!?rig.String {
    const io = rig.io();
    // Opened as a directory may be, so that one stat gives both what it is
    // and its size: Zig's own check for a directory is a second.
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        try absent(err);
        return null;
    };
    defer file.close(io);
    const st = file.stat(io) catch |err| return failure(err);
    if (st.kind == .directory) return error.@"std.file.FileError.is_directory";
    const size = std.math.cast(usize, st.size) orelse rig.oom();
    const sized = st.kind == .file and size > 0;
    var s: rig.String = .empty;
    errdefer rig.dropElement(rig.String, &s);
    _ = s.roomFor(size);
    // Read into the spare capacity; once it is full, a sized file is done,
    // and any other goes on into `probe`, which finds its end without
    // growing the buffer.
    var probe: [4096]u8 = undefined;
    while (true) {
        const spare = s.list.unusedCapacitySlice();
        if (spare.len == 0 and sized) break;
        const into = if (spare.len > 0) spare else &probe;
        const n = file.readStreaming(io, &.{into}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return failure(err),
        };
        if (spare.len > 0) s.list.items.len += n else s.appendBytes(probe[0..n]);
    }
    s.fit();
    return s;
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
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        // A file at the path, or on the way to it, is not a directory.
        if (failure(err) != not_found) return failure(err);
        return null;
    };
    defer dir.close(io);
    var out: Entries = .{};
    errdefer rig.dropElement(Entries, &out);
    // Many entries to a system call, where `iterate`'s 2 KiB holds about
    // 55; and no seek to the start of a directory just opened.
    var buf: [32 << 10]u8 align(@alignOf(usize)) = undefined;
    var reader: std.Io.Dir.Reader = .init(dir, &buf);
    reader.state = .reading;
    while (reader.next(io) catch |err| return failure(err)) |entry| {
        var kind = entry.kind;
        var link = kind == .sym_link;
        // A link's kind is what it names; a kind the directory does not
        // record is looked up.
        if (kind == .unknown) {
            if (dir.statFile(io, entry.name, .{ .follow_symlinks = false })) |here| {
                link = here.kind == .sym_link;
                kind = here.kind;
            } else |_| {}
        }
        if (link) kind = if (dir.statFile(io, entry.name, .{})) |target| target.kind else |_| .unknown;
        out.names.push(fresh(entry.name));
        out.codes.push(kindCode(kind) + @as(i64, if (link) 4 else 0));
    }
    // Sorted in place, the two lists together.
    const Later = struct {
        names: []rig.String,
        codes: []i64,
        pub fn lessThan(s: @This(), a: usize, b: usize) bool {
            return std.mem.order(u8, s.names[a].list.items, s.names[b].list.items) == .gt;
        }
        pub fn swap(s: @This(), a: usize, b: usize) void {
            std.mem.swap(rig.String, &s.names[a], &s.names[b]);
            std.mem.swap(i64, &s.codes[a], &s.codes[b]);
        }
    };
    std.sort.pdqContext(0, out.names.len, Later{ .names = out.names.items(), .codes = out.codes.items() });
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
    var got = try rig.net.fileRead(fd, want);
    defer rig.dropElement(rig.String, &got);
    const n = got.list.items.len;
    // Into a String with no buffer yet, the read's own is taken, not copied.
    if (into.list.capacity == 0) std.mem.swap(rig.String, into, &got) else into.appendBytes(got.list.items);
    return @intCast(n);
}

pub fn write_to(fd: i64, bytes: []const u8) Error!void {
    return rig.net.fileWrite(fd, bytes);
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
    return .ofBytes(bytes);
}
