//! `std.file`: reading a whole file into a `String` the runtime's
//! allocator owns, so the leak checker and the sanitizer see it, and
//! asking what is at a path. Every call runs on the blocking pool
//! (`rig.blocking`), so only the task making it waits.

const std = @import("std");
const rig = @import("../runtime.zig");

/// The file at `path`, relative to the working directory, in a String
/// whose buffer holds exactly its bytes, or null when it cannot be
/// opened as a file or read. A regular file's size sizes the buffer;
/// a file that grows while it is read, or one that reports no size
/// (a pipe, a device), is read to its end and the buffer trimmed.
pub fn read(path: []const u8) ?rig.String {
    return rig.blocking(readHere, .{path});
}

/// `read` on the thread it runs on, which may block.
fn readHere(path: []const u8) ?rig.String {
    const io = rig.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false }) catch return null;
    defer file.close(io);
    const gpa = rig.defaultAllocator();
    var list: std.ArrayList(u8) = .empty;
    const size = std.math.cast(usize, file.length(io) catch return null) orelse rig.oom();
    list.ensureTotalCapacityPrecise(gpa, size) catch rig.oom();
    // Read into the spare capacity; once it is full, into `probe`, which
    // finds the end of a regular file without growing the buffer.
    var probe: [4096]u8 = undefined;
    while (true) {
        const spare = list.unusedCapacitySlice();
        const into = if (spare.len > 0) spare else &probe;
        const n = file.readStreaming(io, &.{into}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                list.deinit(gpa);
                return null;
            },
        };
        if (spare.len > 0) list.items.len += n else list.appendSlice(gpa, probe[0..n]) catch rig.oom();
    }
    if (list.capacity != list.items.len) list.shrinkAndFreePrecise(gpa, list.items.len) catch rig.oom();
    return .{ .list = list };
}

/// The absolute path `path` names, links resolved, or null when nothing
/// is there.
pub fn realpath(path: []const u8) ?rig.String {
    return rig.blocking(realpathHere, .{path});
}

fn realpathHere(path: []const u8) ?rig.String {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(rig.io(), path, &buf) catch return null;
    return fresh(buf[0..n]);
}

/// `stat`'s answer as one number (std/file.rig), or null when nothing is
/// at `path`.
pub fn stat_code(path: []const u8) ?i64 {
    return rig.blocking(statHere, .{path});
}

fn statHere(path: []const u8) ?i64 {
    const io = rig.io();
    const cwd = std.Io.Dir.cwd();
    const here = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch return null;
    if (here.kind != .sym_link) return code(here.kind, false, here.size);
    const target = cwd.statFile(io, path, .{}) catch return code(.unknown, true, 0);
    return code(target.kind, true, target.size);
}

/// A kind, whether it came through a link, and a size, as `stat_code`
/// and `dir_entries` give them.
fn code(kind: std.Io.File.Kind, link: bool, size: u64) i64 {
    const k: i64 = switch (kind) {
        .file => 0,
        .directory => 1,
        else => 2,
    };
    const bytes: i64 = @intCast(@min(size, std.math.maxInt(i64) >> 3));
    return bytes * 8 + (if (link) @as(i64, 4) else 0) + k;
}

/// The entries of the directory at `path`, last name first, onto `names`,
/// and each one's kind, plus 4 for a link, onto `codes`; false when it
/// cannot be read as a directory.
pub fn dir_entries(path: []const u8, names: *rig.List(rig.String), codes: *rig.List(i64)) bool {
    return rig.blocking(entriesHere, .{ path, names, codes });
}

fn entriesHere(path: []const u8, names: *rig.List(rig.String), codes: *rig.List(i64)) bool {
    const io = rig.io();
    const gpa = std.heap.smp_allocator;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    const Found = struct { name: []u8, code: i64 };
    var found: std.ArrayList(Found) = .empty;
    defer {
        for (found.items) |f| gpa.free(f.name);
        found.deinit(gpa);
    }
    var it = dir.iterate();
    while (it.next(io) catch return false) |entry| {
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
        found.append(gpa, .{ .name = name, .code = @mod(code(kind, link, 0), 8) }) catch rig.oom();
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

/// A fresh String of `bytes`.
fn fresh(bytes: []const u8) rig.String {
    var s: rig.String = .empty;
    s.list.appendSlice(rig.defaultAllocator(), bytes) catch rig.oom();
    return s;
}
