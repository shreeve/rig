//! `std.task`: the waiting point that waits for nothing.

const rig = @import("../runtime.zig");

pub const check = rig.taskCheck;
pub const workers = rig.taskWorkers;
pub const worker_count = rig.taskWorkerCount;
pub const fast_cores = rig.fastCores;

/// PHASE-WIDE (scratch, measurement only): `task.widen()` and
/// `task.narrow()`, which do nothing unless `RIG_WIDE=1` (`sched.widen`).
pub fn widen() void {
    if (rig.scheduled) rig.sched.widen();
}

pub fn narrow() void {
    if (rig.scheduled) rig.sched.narrow();
}
