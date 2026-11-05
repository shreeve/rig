// pcore CMD...: run CMD, then print its wall ms, CPU ms, the share of its
// CPU time on performance cores, and its CPU time by QoS class, from
// proc_pid_rusage(RUSAGE_INFO_V6) read while it is a zombie.
const std = @import("std");
const RU = extern struct {
    uuid: [16]u8,
    user_time: u64, system_time: u64, pkg_idle_wkups: u64, interrupt_wkups: u64, pageins: u64,
    wired_size: u64, resident_size: u64, phys_footprint: u64, proc_start_abstime: u64, proc_exit_abstime: u64,
    child_user_time: u64, child_system_time: u64, child_pkg_idle_wkups: u64, child_interrupt_wkups: u64,
    child_pageins: u64, child_elapsed_abstime: u64, diskio_bytesread: u64, diskio_byteswritten: u64,
    qos_default: u64, qos_maintenance: u64, qos_background: u64, qos_utility: u64, qos_legacy: u64,
    qos_user_initiated: u64, qos_user_interactive: u64, billed_system_time: u64, serviced_system_time: u64,
    logical_writes: u64, lifetime_max_phys_footprint: u64, instructions: u64, cycles: u64,
    billed_energy: u64, serviced_energy: u64, interval_max_phys_footprint: u64, runnable_time: u64,
    flags: u64, user_ptime: u64, system_ptime: u64, pinstructions: u64, pcycles: u64,
    rest: [20]u64,
};
const Timebase = extern struct { numer: u32, denom: u32 };
extern "c" fn posix_spawnp(pid: *c_int, file: [*:0]const u8, fa: ?*anyopaque, attr: ?*anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitid(idtype: c_int, id: c_uint, info: *[128]u8, options: c_int) c_int;
extern "c" fn waitpid(pid: c_int, st: *c_int, options: c_int) c_int;
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buf: *RU) c_int;
extern "c" fn mach_timebase_info(tb: *Timebase) c_int;
extern "c" fn clock_gettime_nsec_np(clock: c_uint) u64;
extern "c" var environ: [*:null]const ?[*:0]const u8;
const P_PID = 1;
const WEXITED = 0x04;
const WNOWAIT = 0x20;
const CLOCK_MONOTONIC_RAW = 4;
var tb: Timebase = undefined;
fn ms(v: u64) f64 {
    return @as(f64, @floatFromInt(v)) * @as(f64, @floatFromInt(tb.numer)) / @as(f64, @floatFromInt(tb.denom)) / 1e6;
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var argv: [64:null]?[*:0]const u8 = @splat(null);
    for (args[1..], 0..) |a, i| argv[i] = a.ptr;
    _ = mach_timebase_info(&tb);
    var pid: c_int = 0;
    const t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    if (posix_spawnp(&pid, argv[0].?, null, null, &argv, environ) != 0) return error.Spawn;
    var info: [128]u8 = undefined;
    _ = waitid(P_PID, @intCast(pid), &info, WEXITED | WNOWAIT);
    const t1 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    var ru: RU = undefined;
    if (proc_pid_rusage(pid, 6, &ru) != 0) return error.Rusage;
    var st: c_int = 0;
    _ = waitpid(pid, &st, 0);
    const cpu = ms(ru.user_time + ru.system_time);
    const p = ms(ru.user_ptime + ru.system_ptime);
    std.debug.print("pcore wall {d:.1} cpu {d:.1} p {d:.1} pshare {d:.1}% runnable {d:.1} qos def {d:.1} ui {d:.1} ux {d:.1} ut {d:.1} cyc {d} pcyc {d}\n", .{
        @as(f64, @floatFromInt(t1 - t0)) / 1e6, cpu, p, 100 * p / cpu, ms(ru.runnable_time),
        ms(ru.qos_default), ms(ru.qos_user_initiated), ms(ru.qos_user_interactive), ms(ru.qos_utility),
        ru.cycles, ru.pcycles,
    });
}
