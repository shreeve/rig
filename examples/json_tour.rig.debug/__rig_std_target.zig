const std = @import("std");
const rig = @import("rig/runtime.zig");

const __rig_shim_1 = @import("rig/std/target.zig");
pub const arch: rig.Arch = __rig_shim_1.arch;
