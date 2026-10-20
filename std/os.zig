//! `std.os`: the process's arguments and environment, which the runtime
//! stores when the program starts (`rig.start`). Both live as long as
//! the process, so they cross into Rig as `Static`s.

const std = @import("std");
const rig = @import("../runtime.zig");

pub fn args() []const []const u8 {
    return rig.processArgs();
}

pub fn env(name: []const u8) ?[]const u8 {
    const init = rig.process orelse return null;
    return init.environ.getPosix(name);
}

/// The working directory, as an absolute path.
pub fn cwd() rig.String {
    return rig.blocking(cwdHere, .{});
}

fn cwdHere() rig.String {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(rig.io(), &buf) catch return .empty;
    var s: rig.String = .empty;
    s.list.appendSlice(rig.defaultAllocator(), buf[0..n]) catch rig.oom();
    return s;
}
