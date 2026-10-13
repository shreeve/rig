//! `std.file`: reading a whole file into a `String` the runtime's
//! allocator owns, so the leak checker and the sanitizer see it.

const std = @import("std");
const rig = @import("../runtime.zig");

/// The file at `path`, relative to the working directory, in a String
/// whose buffer holds exactly its bytes, or null when it cannot be
/// opened as a file or read. A regular file's size sizes the buffer;
/// a file that grows while it is read, or one that reports no size
/// (a pipe, a device), is read to its end and the buffer trimmed.
pub fn read(path: []const u8) ?rig.String {
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
