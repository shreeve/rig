// exitwatch CMD...: run CMD traced only for its exit (PTRACE_O_TRACEEXIT), Linux.
// When it stops at its exit, before the kernel tears its memory down, note the
// time and its resident memory, let it go, and wait for it to be reaped. Prints
// to stderr: `exitwatch at-exit MS reaped MS rss-at-exit KB status S`, times
// from the spawn. With EXITWATCH_PLAIN=1 it only times the reaping. "at-exit" is the wall a caller would see if the process
// handed off its exit; "reaped" is the wall it sees today.
const std = @import("std");
const linux = std.os.linux;

const PTRACE_TRACEME = 0;
const PTRACE_CONT = 7;
const PTRACE_DETACH = 17;
const PTRACE_SETOPTIONS = 0x4200;
const PTRACE_GETEVENTMSG = 0x4201;
const PTRACE_O_TRACEEXIT = 0x40;
const PTRACE_EVENT_EXIT = 6;

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn rssKb(pid: i32) u64 {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "/proc/{d}/status", .{pid}, 0) catch return 0;
    const fd: i32 = @intCast(@as(isize, @bitCast(linux.open(path, .{}, 0))));
    if (fd < 0) return 0;
    defer _ = linux.close(fd);
    var text: [8192]u8 = undefined;
    const n = linux.read(fd, &text, text.len);
    if (@as(isize, @bitCast(n)) <= 0) return 0;
    const s = text[0..n];
    const at = std.mem.indexOf(u8, s, "VmRSS:") orelse return 0;
    var it = std.mem.tokenizeAny(u8, s[at + 6 ..], " \t\n");
    return std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(init.args.vector.ptr + 1);
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(init.environ.block.slice.ptr);
    // EXITWATCH_PLAIN=1: no tracing, the reaped time alone, to check the
    // tracing changes nothing.
    const plain = init.environ.getPosix("EXITWATCH_PLAIN") != null;
    const t0 = now();
    const pid: i32 = @intCast(linux.fork());
    if (pid == 0) {
        if (!plain) _ = linux.ptrace(PTRACE_TRACEME, 0, 0, 0, 0);
        _ = linux.execve(argv[0].?, argv, envp);
        linux.exit_group(127);
    }
    var st: i32 = 0;
    if (!plain) {
        _ = linux.waitpid(pid, &st, 0); // the stop at exec
        _ = linux.ptrace(PTRACE_SETOPTIONS, pid, 0, PTRACE_O_TRACEEXIT, 0);
        _ = linux.ptrace(PTRACE_CONT, pid, 0, 0, 0);
    }
    var t_exit: u64 = 0;
    var rss: u64 = 0;
    var status: u64 = 0;
    while (true) {
        const r = linux.waitpid(pid, &st, 0x40000000); // __WALL
        if (@as(isize, @bitCast(r)) < 0) continue;
        const u: u32 = @bitCast(st);
        if (u & 0x7f == 0 or ((u & 0x7f) != 0x7f)) break; // exited or killed
        const sig = (u >> 8) & 0xff;
        if (sig == @intFromEnum(linux.SIG.TRAP) and (u >> 16) == PTRACE_EVENT_EXIT) {
            t_exit = now();
            rss = rssKb(pid);
            _ = linux.ptrace(PTRACE_GETEVENTMSG, pid, 0, @intFromPtr(&status), 0);
            _ = linux.ptrace(PTRACE_DETACH, pid, 0, 0, 0);
            continue;
        }
        _ = linux.ptrace(PTRACE_CONT, pid, 0, sig, 0);
    }
    const t_reaped = now();
    var buf: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "exitwatch at-exit {d:.2} reaped {d:.2} rss-at-exit {d} status {d}\n", .{
        @as(f64, @floatFromInt(t_exit -| t0)) / 1e6, @as(f64, @floatFromInt(t_reaped - t0)) / 1e6, rss, status >> 8,
    }) catch return;
    _ = linux.write(2, line.ptr, line.len);
}
