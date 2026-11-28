//! `std.task`: the waiting point that waits for nothing, the workers,
//! and the CPUs the program may run on (`rig.cpus`).

const rig = @import("../runtime.zig");

pub const check = rig.taskCheck;
pub const workers = rig.taskWorkers;
pub const worker_count = rig.taskWorkerCount;

pub fn cpus_threads() i64 {
    return @intCast(rig.cpus().threads);
}

pub fn cpus_cores() i64 {
    return @intCast(rig.cpus().cores);
}

pub fn cpus_fast_cores() i64 {
    return @intCast(rig.cpus().fast_cores);
}

pub fn cpus_fast_threads() i64 {
    return @intCast(rig.cpus().fast_threads);
}

pub fn cpus_quota() ?f64 {
    return rig.cpus().quota;
}
