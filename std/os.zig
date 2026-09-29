//! `std.os`: the process's arguments and environment, which the runtime
//! stores when the program starts (`rig.start`). Both live as long as
//! the process, so they cross into Rig as Strings.

const std = @import("std");
const rig = @import("../runtime.zig");

pub fn args() []const []const u8 {
    return rig.processArgs();
}

pub fn env(name: []const u8) ?[]const u8 {
    const init = rig.process orelse return null;
    return init.environ.getPosix(name);
}
