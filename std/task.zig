//! `std.task`: the waiting point that waits for nothing.

const rig = @import("../runtime.zig");

pub const check = rig.taskCheck;
pub const workers = rig.taskWorkers;
pub const worker_count = rig.taskWorkerCount;
pub const fast_cores = rig.fastCores;
