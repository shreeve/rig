//! `std.target`: the target's facts, which Zig knows when it compiles
//! the program for that target.

const builtin = @import("builtin");
const rig = @import("../runtime.zig");

pub const arch = builtin.cpu.arch;
pub const os = builtin.os.tag;
/// A debug build: the one `rig run`, `rig test` and `rig build` without
/// `--release` make, which checks for leaks (runtime.zig's `leak_checked`).
pub const debug = builtin.optimize == .debug;

/// Whether the CPU the program is compiled for has `f`: a constant when
/// `f` is one.
pub inline fn has(f: rig.Feature) bool {
    return rig.hasFeature(f);
}
