//! The exit handoff, in a program built with `RIG_EXIT_HANDOFF=1`
//! (docs/internals/INTERNALS.md, "The exit handoff"). The process forks
//! before anything else: the child runs the program, and the parent only
//! waits. As the program ends, the child flushes its output, closes its
//! standard streams, and writes its exit status into a pipe; the parent
//! exits at once with that status, which is quick because it holds
//! almost no memory. The child then tears its memory down with no one
//! waiting on it. A child that dies before it writes a status, by a
//! panic, a signal, or any exit that does not pass through `end`, closes
//! the pipe as it dies; the parent then waits for it and ends as it did:
//! with its status, or by its signal.
//!
//! Signals: the child is in the parent's process group, so what the
//! terminal sends the group (Ctrl-C, Ctrl-\, Ctrl-Z, a hangup, a resize)
//! reaches the child directly, and the parent ignores it or stops with
//! it. A signal a process sends the parent by its pid (`kill PID`,
//! `timeout`) is passed on to the child. One sent to the whole group
//! reaches the child twice.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

/// Where the handoff is built: Linux and macOS.
pub const supported = builtin.os.tag == .linux or builtin.os.tag == .macos;

/// In the child, its end of the pipe to the parent; -1 elsewhere, and
/// once the status is written.
var notify_fd: i32 = -1;
/// In the parent, the child's pid.
var child: i32 = 0;

/// The signals the parent passes on to the child when a process sends
/// them to the parent's pid.
const passed = [_]std.posix.SIG{ .INT, .TERM, .HUP, .QUIT, .USR1, .USR2, .ALRM, .CONT };

/// Fork, first thing in the program. The child returns, to run the
/// program; the parent never returns. A pipe or a fork that fails leaves
/// the program running in this process, as if it were built without the
/// handoff.
pub fn begin() void {
    var fds: [2]i32 = undefined;
    if (!pipe(&fds)) return;
    const parent = getpid();
    const pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return;
    }
    if (pid == 0) {
        close(fds[0]);
        notify_fd = fds[1];
        // On Linux the child dies with the parent, so `kill -9` of the
        // pid the caller knows ends the program too.
        if (builtin.os.tag == .linux) {
            _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), 9, 0, 0, 0);
            if (linux.getppid() != parent) exitNow(1);
        }
        return;
    }
    close(fds[1]);
    wait(pid, fds[0]);
}

/// In the child, as the program ends with `status`, after its output is
/// flushed: close the standard streams, so whoever reads them sees their
/// end, then hand the status to the parent. Later calls do nothing.
pub fn end(status: u8) void {
    const fd = notify_fd;
    if (fd < 0) return;
    notify_fd = -1;
    if (builtin.os.tag == .linux) _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), 0, 0, 0, 0);
    close(0);
    close(1);
    close(2);
    const b = [1]u8{status};
    _ = std.posix.system.write(fd, &b, 1);
    close(fd);
}

/// The status `onOwnStack`'s `f` returned, when it is what the process
/// exits with: `main`'s own result (a `sub main` gives 0, a `fun main`
/// its status). A failure, or a status out of range, goes another way
/// out (`failMain`, `exitStatus`'s panic), which the parent sees by the
/// child's death.
pub fn mainReturned(result: anytype) void {
    const T = @TypeOf(result);
    switch (@typeInfo(T)) {
        .void => end(0),
        .int => if (std.math.cast(u8, result)) |s| end(s),
        .error_union => if (result) |v| mainReturned(v) else |_| {},
        else => {},
    }
}

/// The parent's life: close its standard streams, pass on the signals
/// processes send it, and end as the child does.
fn wait(pid: i32, fd: i32) noreturn {
    child = pid;
    close(0);
    close(1);
    close(2);
    const act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = pass },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO | std.posix.SA.RESTART,
    };
    for (passed) |sig| std.posix.sigaction(sig, &act, null);
    var b: [1]u8 = undefined;
    // `read` retries a read a signal interrupts.
    const n = std.posix.read(fd, &b) catch 0;
    if (n == 1) exitNow(b[0]);
    // No status: the child died. End as it did.
    var st: i32 = 0;
    while (true) {
        const r = waitpid(pid, &st);
        if (r == pid) break;
        if (r < 0) exitNow(1);
    }
    if (st & 0x7f == 0) exitNow(@intCast((st >> 8) & 0xff));
    const sig: u8 = @intCast(st & 0x7f);
    // Die by the child's signal, with no core of this process's own.
    std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch {};
    // Its own handler, or the one Zig's start installed for a fault,
    // would catch it: take it back first. SIGKILL and SIGSTOP have none.
    const as: std.posix.SIG = @enumFromInt(sig);
    if (as != .KILL and as != .STOP) {
        const dfl: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(as, &dfl, null);
    }
    var set = std.posix.sigemptyset();
    std.posix.sigaddset(&set, as);
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &set, null);
    std.posix.kill(getpid(), as) catch {};
    exitNow(128 +| sig);
}

/// The parent's handler: a signal a process sent (its pid is not 0) goes
/// on to the child; one the kernel or the terminal raised reached the
/// child itself.
fn pass(sig: std.posix.SIG, info: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const from: i32 = switch (builtin.os.tag) {
        .linux => info.fields.common.first.piduid.pid,
        else => info.pid,
    };
    if (from == 0 or from == child) return;
    std.posix.kill(child, sig) catch {};
}

fn exitNow(status: u8) noreturn {
    if (builtin.link_libc) std.c._exit(status);
    linux.exit_group(status);
}

fn pipe(fds: *[2]i32) bool {
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        return linux.errno(linux.pipe2(fds, .{ .CLOEXEC = true })) == .SUCCESS;
    }
    if (std.c.pipe(fds) != 0) return false;
    for (fds) |fd| _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    return true;
}

fn fork() i32 {
    if (builtin.link_libc) return std.c.fork();
    const r = linux.fork();
    return if (linux.errno(r) == .SUCCESS) @intCast(r) else -1;
}

fn waitpid(pid: i32, st: *i32) i32 {
    if (builtin.link_libc) {
        var s: c_int = 0;
        const r = std.c.waitpid(pid, &s, 0);
        st.* = s;
        return r;
    }
    const r = linux.waitpid(pid, st, 0);
    return switch (linux.errno(r)) {
        .SUCCESS => @intCast(r),
        .INTR => 0,
        else => -1,
    };
}

fn getpid() i32 {
    if (builtin.link_libc) return std.c.getpid();
    return linux.getpid();
}

fn close(fd: i32) void {
    if (builtin.link_libc) _ = std.c.close(fd) else _ = linux.close(fd);
}
