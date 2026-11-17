//! Sockets and the HTTP server, for `std.net` and `std.http`. Each
//! socket does not block, and is registered with a worker's poller
//! (`sched`); an accept, connect, read, or write that would block waits
//! for it to be ready (`sched.waitReady`), under the task's cancel and
//! deadline. A program that makes no tasks waits in `poll` on its own
//! thread. The errors are `std.net.NetError`'s, which the emitter names
//! `error.@"std.net.NetError.name"`, and `std.task.Stop`'s.

const std = @import("std");
const builtin = @import("builtin");
const rig = @import("runtime.zig");
const tasks = @import("tasks.zig");

const posix = std.posix;
const sys = posix.system;
const IpAddress = std.Io.net.IpAddress;

pub const NetError = error{
    @"std.net.NetError.address",
    @"std.net.NetError.in_use",
    @"std.net.NetError.refused",
    @"std.net.NetError.reset",
    @"std.net.NetError.closed",
    @"std.net.NetError.failed",
};
pub const Error = rig.Stop || NetError;

const canceled = error.@"std.task.Stop.canceled";
const timeout = error.@"std.task.Stop.timeout";
const darwin = builtin.os.tag.isDarwin();

/// The error a failed connect reports: no local port free is a failure
/// here, not a bad address.
fn connectFailure(e: posix.E) NetError {
    if (e == .ADDRNOTAVAIL) return error.@"std.net.NetError.failed";
    return failure(e);
}

/// The error a failed call reports.
fn failure(e: posix.E) NetError {
    return switch (e) {
        .ADDRINUSE => error.@"std.net.NetError.in_use",
        .CONNREFUSED => error.@"std.net.NetError.refused",
        .CONNRESET => error.@"std.net.NetError.reset",
        .PIPE, .NOTCONN, .SHUTDOWN => error.@"std.net.NetError.closed",
        .ADDRNOTAVAIL, .NETUNREACH, .HOSTUNREACH, .AFNOSUPPORT => error.@"std.net.NetError.address",
        else => error.@"std.net.NetError.failed",
    };
}

/// `host:port`: an IPv4 address, `[IPv6]`, `localhost`, or nothing.
fn parse(text: []const u8) NetError!IpAddress {
    const bad = error.@"std.net.NetError.address";
    if (text.len > 0 and text[0] == '[') return IpAddress.parseLiteral(text) catch bad;
    const colon = std.mem.findScalarLast(u8, text, ':') orelse return bad;
    const host = text[0..colon];
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return bad;
    if (host.len == 0) return .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = port } };
    if (std.mem.eql(u8, host, "localhost")) return .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } };
    return IpAddress.parse(host, port) catch bad;
}

/// A socket address the system takes, for `a`.
const SockAddr = struct {
    storage: sys.sockaddr.in6 = undefined,
    len: posix.socklen_t = 0,
    family: u32 = 0,

    fn of(a: IpAddress) SockAddr {
        var out: SockAddr = .{};
        switch (a) {
            .ip4 => |ip| {
                const in: sys.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, ip.port), .addr = @bitCast(ip.bytes) };
                @memcpy(std.mem.asBytes(&out.storage)[0..@sizeOf(sys.sockaddr.in)], std.mem.asBytes(&in));
                out.len = @sizeOf(sys.sockaddr.in);
                out.family = posix.AF.INET;
            },
            .ip6 => |ip| {
                out.storage = .{ .port = std.mem.nativeToBig(u16, ip.port), .flowinfo = ip.flow, .addr = ip.bytes, .scope_id = ip.interface.index };
                out.len = @sizeOf(sys.sockaddr.in6);
                out.family = posix.AF.INET6;
            },
        }
        return out;
    }

    fn ptr(s: *const SockAddr) *const sys.sockaddr {
        return @ptrCast(&s.storage);
    }
};

/// A non-blocking stream socket of `family`.
fn socket(family: u32) NetError!i32 {
    const flags: u32 = if (darwin) 0 else posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;
    const rc = sys.socket(family, posix.SOCK.STREAM | flags, 0);
    if (posix.errno(rc) != .SUCCESS) return failure(posix.errno(rc));
    const fd: i32 = @intCast(rc);
    if (darwin) nonblocking(fd);
    return fd;
}

/// Send each write at once, never holding small ones back to join the
/// next (Nagle's algorithm), which delays a request that follows one
/// still unanswered by the other end's delayed acknowledgment: every
/// accepted and connected stream does.
fn noDelay(fd: i32) void {
    setOption(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, 1);
}

/// Set a socket option to `value`, whatever the system answers: on a
/// connection the other end has reset, even one reset before it was
/// accepted, macOS refuses every option (EINVAL), which Zig's
/// `posix.setsockopt` takes for a bug and stops on; the connection's
/// next read or write meets the reset as its failure.
fn setOption(fd: i32, level: i32, name: u32, value: c_int) void {
    _ = sys.setsockopt(fd, level, name, std.mem.asBytes(&value), @sizeOf(c_int));
}

/// macOS sets a socket not to block after it is made.
fn nonblocking(fd: i32) void {
    if (!darwin) return;
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    _ = std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
    _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
}

/// How long a wait may last besides the task's own deadline: until an
/// instant (`at`), and no longer than `idle` from when it begins. The
/// HTTP server sets these for its connections (`Conn`), with the
/// connection's deadline (`timer`), which carries each wait's deadline
/// to its worker's timers without setting a timer for each wait
/// (`sched.Deadline`); a call from Rig sets none.
const Limit = struct {
    at: ?i96 = null,
    idle: ?i96 = null,
    timer: ?*rig.sched.Deadline = null,

    /// The deadline of a wait that begins now: the earliest of the
    /// limit's and the task's.
    fn deadline(l: Limit, task: ?i96) ?i96 {
        var d = task;
        if (l.at) |a| d = if (d) |x| @min(x, a) else a;
        if (l.idle) |i| {
            const end = rig.sched.nowNs() + i;
            d = if (d) |x| @min(x, end) else end;
        }
        return d;
    }
};

/// The edges the poller has seen `reg` become ready for `interest`
/// (`sched.edges`), read before a call that may find it not ready, to
/// pass to `waitFor`; 0 outside the scheduler.
fn edges(reg: i64, interest: u32) u32 {
    if (reg == 0) return 0;
    return rig.sched.edges(@ptrFromInt(@as(usize, @intCast(reg))), interest);
}

/// Whether a read on `reg` would find nothing, by the edges `seen`
/// before it (`sched.drained`): it waits first. Only on the scheduler,
/// whose poller counts the edges.
fn drained(reg: i64, seen: u32) bool {
    if (reg == 0 or rig.sched.current() == null) return false;
    return rig.sched.drained(@ptrFromInt(@as(usize, @intCast(reg))), seen);
}

/// A read on `reg` took `n` bytes of the `asked`, with the edges `seen`
/// before it: fewer is all there were (`sched.readCame`).
fn readCame(reg: i64, seen: u32, n: usize, asked: usize) void {
    if (reg == 0 or n == 0) return;
    rig.sched.readCame(@ptrFromInt(@as(usize, @intCast(reg))), seen, n < asked);
}

/// Wait for `fd` to be ready for `interest`, after a call that would have
/// blocked: on its poller, for an edge past `seen`, read before the call
/// (`edges`), or, outside the scheduler, in `poll`; no longer than
/// `limit` allows. A task whose descriptor the poller refused fails,
/// rather than block its worker.
fn waitFor(fd: i32, reg: i64, interest: u32, seen: u32, limit: Limit) Error!void {
    const t = rig.task();
    const deadline = limit.deadline(t.deadline);
    if (rig.sched.current() != null) {
        if (reg == 0) return error.@"std.net.NetError.failed";
        const r: *rig.sched.Registration = @ptrFromInt(@as(usize, @intCast(reg)));
        const readiness = if (limit.timer != null and deadline != null)
            rig.sched.waitReadyBy(r, interest, seen, limit.timer.?, deadline.?, true)
        else
            rig.sched.waitReady(r, interest, seen, deadline, true);
        return switch (readiness) {
            .ready => {},
            .canceled => canceled,
            .timeout => timeout,
        };
    }
    const events: i16 = if (interest == rig.sched.Registration.readable) posix.POLL.IN else posix.POLL.OUT;
    var fds = [1]posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    var ms: i32 = -1;
    if (deadline) |d| {
        const left = d - rig.sched.nowNs();
        if (left <= 0) return timeout;
        ms = @intCast(@min(@divTrunc(left + std.time.ns_per_ms - 1, std.time.ns_per_ms), std.math.maxInt(i32)));
    }
    // An interrupt ends the poll (EINTR) to cancel `main`
    // (`rig.cancelOnInterrupt`), which Zig's `poll` would only restart.
    rig.flushBeforeWait();
    while (true) {
        const rc = sys.poll(&fds, fds.len, ms);
        switch (posix.errno(rc)) {
            .SUCCESS => return if (rc == 0) timeout else {},
            .INTR => try rig.checkStop(),
            else => return error.@"std.net.NetError.failed",
        }
    }
}

pub fn listen_on(addr: []const u8) Error!i64 {
    const sa = SockAddr.of(try parse(addr));
    const fd = try socket(sa.family);
    errdefer _ = sys.close(fd);
    setOption(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, 1);
    var rc = sys.bind(fd, sa.ptr(), sa.len);
    if (posix.errno(rc) != .SUCCESS) return failure(posix.errno(rc));
    rc = sys.listen(fd, 1024);
    if (posix.errno(rc) != .SUCCESS) return failure(posix.errno(rc));
    return fd;
}

pub fn open_to(addr: []const u8) Error!i64 {
    try rig.checkStop();
    const sa = SockAddr.of(try parse(addr));
    const fd = try socket(sa.family);
    noDelay(fd);
    const rc = sys.connect(fd, sa.ptr(), sa.len);
    switch (posix.errno(rc)) {
        .SUCCESS, .INPROGRESS, .INTR => return fd,
        else => |e| {
            _ = sys.close(fd);
            return connectFailure(e);
        },
    }
}

pub fn finish_connect(fd: i64, reg: i64) Error!void {
    const s: i32 = @intCast(fd);
    // The connect began before the socket was registered, so any edge the
    // registration has seen may be the one it waits for: it waits past
    // none.
    try waitFor(s, reg, rig.sched.Registration.writable, 0, .{});
    var err: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);
    _ = sys.getsockopt(s, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&err), &len);
    if (err != 0) return connectFailure(@enumFromInt(err));
}

pub fn watch(fd: i64) i64 {
    if (!rig.scheduled) return 0;
    const r = rig.sched.register(@intCast(fd)) orelse return 0;
    return @intCast(@intFromPtr(r));
}

pub fn accept_on(fd: i64, reg: i64) Error!i64 {
    return try acceptOne(@intCast(fd), reg) orelse error.@"std.net.NetError.failed";
}

/// The next connection on `s`, once one comes, or null when the process
/// or the system has run out of descriptors or memory for one.
fn acceptOne(s: i32, reg: i64) Error!?i32 {
    try rig.checkStop();
    while (true) {
        const seen = edges(reg, rig.sched.Registration.readable);
        const rc = if (darwin) sys.accept(s, null, null) else sys.accept4(s, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const c: i32 = @intCast(rc);
                nonblocking(c);
                noDelay(c);
                return c;
            },
            .AGAIN => try waitFor(s, reg, rig.sched.Registration.readable, seen, .{}),
            .CONNABORTED => {},
            .INTR => try rig.checkStop(),
            .MFILE, .NFILE, .NOBUFS, .NOMEM => return null,
            else => |e| return failure(e),
        }
    }
}

pub fn local_port(fd: i64) i64 {
    var storage: sys.sockaddr.in6 = undefined;
    var len: posix.socklen_t = @sizeOf(sys.sockaddr.in6);
    if (posix.errno(sys.getsockname(@intCast(fd), @ptrCast(&storage), &len)) != .SUCCESS) return 0;
    // The port is at the same place in an IPv4 and an IPv6 address.
    return std.mem.bigToNative(u16, storage.port);
}

/// Read up to `max` bytes onto the end of `into`, once any come: how
/// many, or 0 once the other end has closed. A String with room for
/// `max` more is read into; one without, on the scheduler, is read
/// through the worker's block (`readKept`), so a task waiting for bytes
/// holds no buffer for them, and the String grows by only the bytes that
/// came.
pub fn read_from(fd: i64, reg: i64, into: *rig.String, max: i64) Error!i64 {
    const want: usize = @intCast(@max(max, 0));
    if (want == 0) return 0;
    const s: i32 = @intCast(fd);
    if (into.list.unusedCapacitySlice().len < want and reg != 0 and rig.sched.current() != null) return @intCast(try readKept(s, reg, into, want));
    const n = try readSome(s, reg, into.roomFor(want), .{});
    into.list.items.len += n;
    return @intCast(n);
}

/// `read_from` for a String without room for `want` more bytes: read
/// into a block of the worker's, holding none while it waits, and add
/// the bytes that came to `into`, one copy of them. A block that comes
/// back full may have more waiting behind it, which is read straight
/// into `into`, so a large read copies no more than a block.
fn readKept(s: i32, reg: i64, into: *rig.String, want: usize) Error!usize {
    try rig.checkStop();
    while (true) {
        const seen = edges(reg, rig.sched.Registration.readable);
        if (drained(reg, seen)) {
            try waitFor(s, reg, rig.sched.Registration.readable, seen, .{});
            continue;
        }
        const b = rig.sched.takeBlock();
        const asked = @min(want, b.len);
        const rc = sys.read(s, b, asked);
        const e = posix.errno(rc);
        if (e == .SUCCESS) {
            const n: usize = @intCast(rc);
            // Room as Zig's lists grow, half as much again and a cache
            // line more, so a server's small reads fall in few size
            // classes, each of which every worker's heap holds a page of:
            // grown exactly, a server of 22 workers holds 0.9 MB more.
            const used = into.list.items.len;
            if (into.list.unusedCapacitySlice().len < n) _ = into.roomFor(std.ArrayList(u8).growCapacity(used + n) - used);
            into.appendBytes(b[0..n]);
            rig.sched.giveBlock(b);
            if (n < asked or n == want) {
                readCame(reg, seen, n, asked);
                return n;
            }
            const more = readMore(s, into, want - n);
            readCame(reg, seen, more, want - n);
            return n + more;
        }
        rig.sched.giveBlock(b);
        switch (e) {
            .AGAIN => try waitFor(s, reg, rig.sched.Registration.readable, seen, .{}),
            .INTR => try rig.checkStop(),
            else => return failure(e),
        }
    }
}

/// Read up to `more` bytes onto the end of `into`, those already waiting
/// and no others: 0 when none are, or on any failure, which the next
/// read meets again.
fn readMore(s: i32, into: *rig.String, more: usize) usize {
    const room = into.roomFor(more);
    while (true) {
        const rc = sys.read(s, room.ptr, more);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                into.list.items.len += n;
                return n;
            },
            .INTR => {},
            else => return 0,
        }
    }
}

/// Read what comes into `dest`, once any does: how many bytes, or 0 once
/// the other end has closed.
fn readSome(s: i32, reg: i64, dest: []u8, limit: Limit) Error!usize {
    try rig.checkStop();
    while (true) {
        const seen = edges(reg, rig.sched.Registration.readable);
        if (drained(reg, seen)) {
            try waitFor(s, reg, rig.sched.Registration.readable, seen, limit);
            continue;
        }
        const rc = sys.read(s, dest.ptr, dest.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                readCame(reg, seen, n, dest.len);
                return n;
            },
            .AGAIN => try waitFor(s, reg, rig.sched.Registration.readable, seen, limit),
            .INTR => try rig.checkStop(),
            else => |e| return failure(e),
        }
    }
}

pub fn write_to(fd: i64, reg: i64, bytes: []const u8) Error!void {
    return writeAll(@intCast(fd), reg, bytes, .{});
}

/// Write all of `bytes`, each wait no longer than `limit` allows.
fn writeAll(s: i32, reg: i64, bytes: []const u8, limit: Limit) Error!void {
    try rig.checkStop();
    var at: usize = 0;
    while (at < bytes.len) {
        const seen = edges(reg, rig.sched.Registration.writable);
        const rc = sys.write(s, bytes[at..].ptr, bytes.len - at);
        switch (posix.errno(rc)) {
            .SUCCESS => at += @intCast(rc),
            .AGAIN => try waitFor(s, reg, rig.sched.Registration.writable, seen, limit),
            .INTR => try rig.checkStop(),
            else => |e| return failure(e),
        }
    }
}

pub fn close(fd: i64, reg: i64) void {
    if (fd < 0) return;
    if (reg != 0) rig.sched.deregister(@ptrFromInt(@as(usize, @intCast(reg))));
    _ = sys.close(@intCast(fd));
}

/// `on`: let the system hold small writes and send them together
/// (TCP_NODELAY off); otherwise send each at once, as every stream
/// begins (`noDelay`).
pub fn batch_on(fd: i64, on: bool) void {
    setOption(@intCast(fd), posix.IPPROTO.TCP, posix.TCP.NODELAY, if (on) 0 else 1);
}

/// The count of a split stream's halves, a `Reader` and a `Writer`,
/// which share its descriptor and its registration: the registration
/// keeps a waiter to read and one to write, so a task may wait on each
/// half at once. The last half to go closes them (`release`).
const Pair = std.atomic.Value(u32);

pub fn share() i64 {
    const p = rig.defaultAllocator().create(Pair) catch rig.oom();
    p.* = .init(2);
    return @intCast(@intFromPtr(p));
}

/// Shut `fd` down for writing: the other end reads the end of the
/// connection. A connection already reset or closed has nothing to end.
pub fn end_writing(fd: i64) void {
    _ = sys.shutdown(@intCast(fd), posix.SHUT.WR);
}

/// One half of a split stream is gone: the last closes the descriptor,
/// once, and frees the count.
pub fn release(fd: i64, reg: i64, pair: i64) void {
    const p: *Pair = @ptrFromInt(@as(usize, @intCast(pair)));
    if (p.fetchSub(1, .acq_rel) != 1) return;
    rig.defaultAllocator().destroy(p);
    close(fd, reg);
}

// -----------------------------------------------------------------------------
// io.copy
// -----------------------------------------------------------------------------

/// `io.copy(!from, !to)`: read `from` to its end, writing each block to
/// `to`, and give how many bytes. Each is a `*` of a `net.Stream`, whose
/// waits are its poller's, or of a `file.File`, whose calls run on the
/// blocking pool as `fileReadInto` and `fileWrite` run; the checker
/// allows nothing else (`Checker.ioCopy`). One buffer carries every
/// block, read where it is written from, and a file's descriptor is lent
/// once for the whole copy: each block moves both into the pool's call
/// and back.
pub fn copy(from: anytype, to: anytype) anyerror!i64 {
    var src = try copyEnd(from, false);
    defer src.__rig_drop();
    var dst = try copyEnd(to, true);
    defer dst.__rig_drop();
    var buf: rig.String = .empty;
    defer rig.dropElement(rig.String, &buf);
    var total: i64 = 0;
    while (true) {
        buf.list.clearRetainingCapacity();
        const room = buf.roomFor(copy_block);
        if (comptime isStream(@TypeOf(from))) {
            buf.list.items.len = try readSome(@intCast(from.fd), from.reg, room, .{});
        } else try trip(readOnto, &src, &buf, @as(usize, copy_block));
        const n = buf.list.items.len;
        if (n == 0) return total;
        if (comptime isStream(@TypeOf(to))) {
            try writeAll(@intCast(to.fd), to.reg, buf.list.items, .{});
        } else if (to.fd == 1 or to.fd == 2) {
            try standardWrite(to.fd, buf.list.items);
        } else try trip(writeBuffer, &dst, &buf, {});
        total += @intCast(n);
    }
}

/// The size of `copy`'s blocks: 64 KiB.
const copy_block = 64 << 10;

/// Whether `copy`'s end, a pointer of type `P`, is a `net.Stream`'s.
fn isStream(comptime P: type) bool {
    return @hasField(@typeInfo(P).pointer.child, "reg");
}

/// The descriptor `copy` reads or writes a `file.File` through (`lend`);
/// none for a stream, or for stdout and stderr, written through
/// `print`'s buffer.
fn copyEnd(end: anytype, writes: bool) FileError!Fd {
    if (comptime isStream(@TypeOf(end))) return .none;
    if (writes and (end.fd == 1 or end.fd == 2)) return .none;
    return lend(end.fd);
}

// -----------------------------------------------------------------------------
// A file's reads and writes on the blocking pool
// -----------------------------------------------------------------------------

/// A descriptor a call on the blocking pool owns, closed when dropped:
/// one it opened, or a duplicate of a file's (`lend`). A call that runs
/// here is given the file's own, which it does not own.
pub const Fd = struct {
    fd: i32,
    owned: bool = true,

    pub const none: Fd = .{ .fd = -1, .owned = false };

    pub fn __rig_drop(self: *Fd) void {
        if (self.owned) _ = sys.close(self.fd);
    }
};

/// The descriptor of the file `fd` for a call: a duplicate, closed on
/// exec, for one on the blocking pool, so a task that stops waiting and
/// closes its file leaves the call a descriptor of its own, never a
/// number the system may give out again; `fd` itself for one that runs
/// here (`rig.onPool`).
fn lend(fd: i64) FileError!Fd {
    if (!rig.onPool()) return .{ .fd = @intCast(fd), .owned = false };
    while (true) {
        const rc = sys.fcntl(@intCast(fd), posix.F.DUPFD_CLOEXEC, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => return .{ .fd = @intCast(rc) },
            .INTR => {},
            else => |e| return fileFailure(e),
        }
    }
}

/// What a file's call on the blocking pool takes and gives back: the
/// descriptor it works on, the String it reads onto or writes from, and
/// why it failed.
const Block = struct {
    fd: Fd,
    buf: rig.String = .empty,
    failure: ?(rig.Stop || FileError) = null,
};

/// `f(fd, buf, arg)` on the blocking pool as a fallible waiting point
/// (`rig.blockingStop`): `fd` and `buf` move into the call and come back
/// with its answer, or, from a call that never starts, at once. A task
/// that stops waiting for a call under way leaves both to it, which
/// drops them as it ends: `fd` and `buf` are left empty.
fn trip(comptime f: anytype, fd: *Fd, buf: *rig.String, arg: anytype) (rig.Stop || FileError)!void {
    const Call = struct {
        fn run(b: Block, a: @TypeOf(arg)) Block {
            var out = b;
            f(out.fd.fd, &out.buf, a) catch |err| {
                out.failure = err;
            };
            return out;
        }
    };
    const args = .{ Block{ .fd = fd.*, .buf = buf.* }, arg };
    fd.* = .none;
    buf.* = .empty;
    var back: @TypeOf(args) = .{ Block{ .fd = .none }, arg };
    const got = rig.blockingStop(Call.run, args, &back) catch |err| {
        fd.* = back[0].fd;
        buf.* = back[0].buf;
        return err;
    };
    fd.* = got.fd;
    buf.* = got.buf;
    if (got.failure) |e| return e;
}

/// Read up to `want` bytes of the file `fd` (a `file.File`'s) onto the
/// end of `into`, into its own buffer, on the blocking pool (`trip`): how
/// many, 0 at the end of the file. The String grows first, here, when it
/// has no room for `want` more; then it moves into the call, which fills
/// it and gives it back, so the bytes are read where they stay and
/// nothing is copied. A cancel or a deadline that ends the wait before
/// the read starts leaves `into` as it was; one that ends it while the
/// read is under way leaves the buffer to the read, so `into` is left
/// empty. A String with no
/// buffer before the read is cut to what came, so a small read keeps no
/// room for `want`.
pub fn fileReadInto(fd: i64, into: *rig.String, want: usize) (rig.Stop || FileError)!usize {
    if (want == 0) return 0;
    const bare = into.list.capacity == 0;
    _ = into.roomFor(want);
    const before = into.list.items.len;
    var d = try lend(fd);
    defer d.__rig_drop();
    try trip(readOnto, &d, into, want);
    if (bare) into.fit();
    return into.list.items.len - before;
}

/// Read up to `want` bytes of `fd` onto the end of `buf`, into the room
/// it has for them: once any come, or none at the end of the file. A
/// descriptor that does not block, as a FIFO's does on macOS
/// (`FifoWait`), waits for them in `poll`.
fn readOnto(fd: i32, buf: *rig.String, want: usize) (rig.Stop || FileError)!void {
    try rig.checkStop();
    const l = &buf.list;
    var w: FifoWait = .{};
    while (true) {
        const rc = sys.read(fd, l.items.ptr + l.items.len, want);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                l.items.len += @intCast(rc);
                return;
            },
            .INTR => try rig.checkStop(),
            .AGAIN => _ = try w.wait(fd),
            else => |e| return fileFailure(e),
        }
    }
}

/// A wait on the blocking pool for a FIFO's bytes, or for the end its
/// writers leave. Linux's `poll` reports both (POLLIN, POLLHUP).
/// macOS's reports the bytes but never the writers' leaving, and a read
/// parked in the kernel can miss it too: a writer that opens the FIFO
/// and closes it, writing nothing, as its reader enters the read leaves
/// that read waiting for good, though the next read gives the end. So
/// on macOS a FIFO's descriptor does not block (`file.open`, and
/// std.file's whole reads), and each wait polls for at most `ms`, from
/// 1 ms, doubling to 64 ms while nothing comes, before the read is made
/// again.
pub const FifoWait = struct {
    ms: i32 = first,

    const first: i32 = if (darwin) 1 else -1;
    const most: i32 = 64;

    /// Wait until `fd` has bytes to read, its writers are gone, or `ms`
    /// has passed; whether the poll reported the writers gone (POLLHUP).
    pub fn wait(w: *FifoWait, fd: i32) (rig.Stop || FileError)!bool {
        var fds = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        while (true) {
            try rig.checkStop();
            const rc = sys.poll(&fds, fds.len, w.ms);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    if (rc > 0) {
                        w.ms = first;
                        return fds[0].revents & posix.POLL.HUP != 0;
                    }
                    w.ms = @min(w.ms * 2, most);
                    return false;
                },
                .INTR => {},
                else => |e| return fileFailure(e),
            }
        }
    }
};

/// A write to stdout through `print`'s buffer, or to stderr after it
/// (`rig.writeStandard`): on the task's own thread, as `print` writes,
/// so not a waiting point.
fn standardWrite(fd: i64, bytes: []const u8) FileError!void {
    const e = rig.writeStandard(fd, bytes);
    if (e != .SUCCESS) return fileFailure(e);
}

/// Write out what `print` has buffered, for `File.flush` of stdout;
/// nothing for any other descriptor, whose writes are not buffered.
pub fn fileFlush(fd: i64) FileError!void {
    if (fd != 1) return;
    const e = rig.flushStandard();
    if (e != .SUCCESS) return fileFailure(e);
}

/// Write all of `bytes` to the file `fd` on the blocking pool, as
/// `fileReadInto` reads, which copies them (`rig.blockingStop`).
pub fn fileWrite(fd: i64, bytes: []const u8) (rig.Stop || FileError)!void {
    if (fd == 1 or fd == 2) return standardWrite(fd, bytes);
    var d = try lend(fd);
    defer d.__rig_drop();
    var none: rig.String = .empty;
    return trip(writeBytes, &d, &none, bytes);
}

fn writeBytes(fd: i32, _: *rig.String, bytes: []const u8) (rig.Stop || FileError)!void {
    return writeFile(fd, bytes);
}

/// `copy`'s write of its buffer.
fn writeBuffer(fd: i32, buf: *rig.String, _: void) (rig.Stop || FileError)!void {
    return writeFile(fd, buf.list.items);
}

fn writeFile(fd: i32, bytes: []const u8) (rig.Stop || FileError)!void {
    try rig.checkStop();
    var at: usize = 0;
    while (at < bytes.len) {
        const rc = sys.write(fd, bytes[at..].ptr, bytes.len - at);
        switch (posix.errno(rc)) {
            .SUCCESS => at += @intCast(rc),
            .INTR => try rig.checkStop(),
            else => |e| return fileFailure(e),
        }
    }
}

/// What `fileSync` writes out: the file's bytes and what the file system
/// records of it, the bytes and what reading them back needs, or the
/// whole file system that holds it.
pub const Sync = enum(u2) { all, data, fs };

/// Write out the file `fd` to its device and wait until the device has
/// it, on the blocking pool as `fileReadInto` reads; for stdout, what
/// `print` buffered is written out first. On macOS `all` and `data` are
/// `F_FULLFSYNC`, which also asks the drive to empty its cache, falling
/// back to `fsync` where a file system or a kind of file does not take
/// it; `fs` is Linux's `syncfs`, and on other systems `sync`, which
/// writes out every file system.
pub fn fileSync(fd: i64, how: Sync) (rig.Stop || FileError)!void {
    try fileFlush(fd);
    var d = try lend(fd);
    defer d.__rig_drop();
    var none: rig.String = .empty;
    return trip(syncFd, &d, &none, how);
}

/// Whether the system has `syncfs`, which writes out one file system.
const has_syncfs = builtin.os.tag == .linux;

fn syncFd(fd: i32, _: *rig.String, how: Sync) (rig.Stop || FileError)!void {
    try rig.checkStop();
    if (how == .fs and !has_syncfs) return sys.sync();
    if (darwin) {
        while (true) switch (posix.errno(sys.fcntl(fd, posix.F.FULLFSYNC, @as(usize, 0)))) {
            .SUCCESS => return,
            .INTR => try rig.checkStop(),
            // A file system that does not take it (an SMB mount gives
            // ENOTSUP), or a kind of file (a pipe gives EBADF): `fsync`,
            // whose reason is the answer.
            .INVAL, .OPNOTSUPP, .NOTTY, .BADF => break,
            else => |e| return fileFailure(e),
        };
    }
    while (true) {
        const rc = switch (how) {
            .all => sys.fsync(fd),
            .data => if (darwin) sys.fsync(fd) else sys.fdatasync(fd),
            .fs => if (has_syncfs) sys.syncfs(fd) else unreachable,
        };
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => try rig.checkStop(),
            else => |e| return fileFailure(e),
        }
    }
}

/// `std.file.FileError`, every member: the emitter names each
/// `error.@"std.file.FileError.name"`, and std/file.zig fails with the
/// same set.
pub const FileError = error{
    @"std.file.FileError.not_found",
    @"std.file.FileError.exists",
    @"std.file.FileError.denied",
    @"std.file.FileError.not_permitted",
    @"std.file.FileError.read_only",
    @"std.file.FileError.not_directory",
    @"std.file.FileError.is_directory",
    @"std.file.FileError.not_empty",
    @"std.file.FileError.link_loop",
    @"std.file.FileError.name_too_long",
    @"std.file.FileError.busy",
    @"std.file.FileError.cross_device",
    @"std.file.FileError.no_space",
    @"std.file.FileError.invalid",
    @"std.file.FileError.bad_descriptor",
    @"std.file.FileError.broken_pipe",
    @"std.file.FileError.io",
    @"std.file.FileError.failed",
};

/// The FileError for a failed system call's `errno`: the one place an
/// errno becomes a member, for std/file.zig as for the reads and writes
/// here.
pub fn fileFailure(e: posix.E) FileError {
    return switch (e) {
        .NOENT => error.@"std.file.FileError.not_found",
        .EXIST => error.@"std.file.FileError.exists",
        .ACCES => error.@"std.file.FileError.denied",
        .PERM => error.@"std.file.FileError.not_permitted",
        .ROFS => error.@"std.file.FileError.read_only",
        .NOTDIR => error.@"std.file.FileError.not_directory",
        .ISDIR => error.@"std.file.FileError.is_directory",
        .NOTEMPTY => error.@"std.file.FileError.not_empty",
        .LOOP => error.@"std.file.FileError.link_loop",
        .NAMETOOLONG => error.@"std.file.FileError.name_too_long",
        .BUSY => error.@"std.file.FileError.busy",
        .XDEV => error.@"std.file.FileError.cross_device",
        .NOSPC => error.@"std.file.FileError.no_space",
        .INVAL => error.@"std.file.FileError.invalid",
        .BADF => error.@"std.file.FileError.bad_descriptor",
        .PIPE => error.@"std.file.FileError.broken_pipe",
        .IO => error.@"std.file.FileError.io",
        else => error.@"std.file.FileError.failed",
    };
}

// -----------------------------------------------------------------------------
// The HTTP server
// -----------------------------------------------------------------------------

/// The server's limits, each read from the environment when `serve`
/// starts, or its default.
const Settings = struct {
    /// How long a connection may wait for its next request, and for each
    /// read of a request's body or write of a response to make progress,
    /// before the server closes it: `RIG_HTTP_IDLE_MS`, 60 seconds.
    idle_ns: i96 = 60 * std.time.ns_per_s,
    /// How long a request's head may take to arrive whole, from its
    /// first byte, before the server closes the connection:
    /// `RIG_HTTP_HEAD_MS`, 10 seconds.
    head_ns: i96 = 10 * std.time.ns_per_s,
    /// The largest request body the server reads: `RIG_HTTP_MAX_BODY`
    /// bytes, 16 MiB. One larger is answered 413, and its connection
    /// closed.
    max_body: u64 = 16 << 20,

    fn read() Settings {
        var s: Settings = .{};
        if (setting("RIG_HTTP_IDLE_MS")) |ms| s.idle_ns = @as(i96, ms) * std.time.ns_per_ms;
        if (setting("RIG_HTTP_HEAD_MS")) |ms| s.head_ns = @as(i96, ms) * std.time.ns_per_ms;
        if (setting("RIG_HTTP_MAX_BODY")) |n| s.max_body = n;
        return s;
    }

    /// The positive whole number the environment variable `name` holds,
    /// or null.
    fn setting(name: []const u8) ?u64 {
        const p = rig.process.* orelse return null;
        const text = p.environ.getPosix(name) orelse return null;
        const n = std.fmt.parseInt(u64, text, 10) catch return null;
        return if (n > 0 and n < 1 << 53) n else null;
    }

    /// The limits of a connection's waits.
    fn limit(s: Settings, head: bool) Limit {
        return .{ .at = if (head) rig.sched.nowNs() + s.head_ns else null, .idle = s.idle_ns };
    }
};
/// The first and the longest pause before accepting again once the
/// process has run out of descriptors: 5 ms, doubling to 1 s.
const accept_pause_ns: i64 = 5 * std.time.ns_per_ms;
/// How much of an unread body a refusing server reads and drops, and for
/// how long, before it closes (`Conn.linger`): 256 KiB, and 1 s.
const linger_bytes: usize = 256 << 10;
const linger_ns: i64 = std.time.ns_per_s;
const linger_poll_ns: i64 = 10 * std.time.ns_per_ms;
const accept_pause_max_ns: i64 = std.time.ns_per_s;

/// `http.serve(<listener, |req| ...)`: take connections on `listener`,
/// each a task of its own, and answer each request on them with what
/// `f` gives for it, until the call is canceled or the listener fails.
/// Out of descriptors, it pauses and accepts again, as Go's server
/// does, so the connections it holds can close. Each connection is
/// registered as it is accepted, with this worker's poller, as a server's
/// own accept loop registers what it accepts (`Listener.accept`): an
/// acceptor waiting for connections sleeps in that poller, and wakes as
/// soon as any of them has bytes to read. Each request runs
/// isolated (`tasks.isolate`): a panic in `f` answers 500, and the
/// server goes on. The connections' tasks end before it
/// returns, and the listener closes then. `f` is a `rig.FnRef` taking a
/// `?http.Request` and giving an `http.Response`, whose fields the
/// runtime fills and reads by name.
///
/// Each connection's task takes a dense stack (`sched.takeDense`), as a
/// task the compiler finds small does, so an idle connection shares page
/// tables with its neighbours. Its own code is this file's and std's
/// HTTP server, with no recursion and no call of the program's, since
/// `f` runs on a stack apart (`tasks.isolate`); its frames reach a few
/// KiB, far below a dense stack's 88 KiB (`sema.dense_depth_limit`), and
/// one deeper would fault in the stack's guard, as any dense stack's
/// does (test/cli/http_idle_footprint.sh measures the saving).
pub fn serve(listener: anytype, f: anytype) anyerror!void {
    var l = listener;
    defer rig.drop(&l);
    const F = @TypeOf(f);
    // The connections' tasks: the set drops each as it ends. At the end,
    // those still open are canceled and waited for.
    var conns: tasks.Tasks(void) = .{};
    defer {
        for (conns.items.items) |t| t.control.cancel();
        conns.__rig_drop();
    }
    const settings: Settings = .read();
    var pause: i64 = accept_pause_ns;
    while (true) {
        const c = try acceptOne(@intCast(@field(l, "fd")), @field(l, "reg")) orelse {
            conns.dropEnded();
            try rig.taskSleep(pause);
            pause = @min(pause * 2, accept_pause_max_ns);
            continue;
        };
        pause = accept_pause_ns;
        conns.add(tasks.Task(void).spawnDense(connection(F), .{ @as(i32, @intCast(c)), watch(c), f, settings }));
    }
}

/// A connection's task: read its requests one after another, and answer
/// each, until it closes, fails, waits too long (`Settings`), or the
/// task is canceled.
fn connection(comptime F: type) fn (i32, i64, F, Settings) void {
    return struct {
        fn run(fd: i32, reg: i64, f: F, settings: Settings) void {
            var c: Conn = undefined;
            c.init(fd, reg, settings);
            defer c.close();
            var server: Server = .init(&c.reader, &c.writer);
            // `init` takes the read buffer's size, which is held later.
            server.http.reader.max_head_len = Conn.buf_size;
            while (true) {
                if (c.reader.bufferedLen() == 0 and !c.fill()) return;
                c.limit = settings.limit(true);
                var request = server.receiveHead() catch |err| switch (err) {
                    // Closed, cut short, too long, or failed: no answer.
                    error.HttpConnectionClosing, error.HttpRequestTruncated, error.HttpHeadersOversize, error.ReadFailed => return,
                    // A head that does not parse, or that `HeadScan`
                    // refuses: 400, and close, since where its body
                    // ends is not known.
                    else => return c.refuseHead(),
                };
                c.limit = settings.limit(false);
                switch (answer(F, f, &request, settings.max_body)) {
                    .next => {},
                    .close => return,
                    .linger => return c.linger(),
                }
            }
        }
    }.run;
}

/// What a connection does once a request is answered.
const Next = enum {
    /// Read the next request.
    next,
    /// Close.
    close,
    /// Close once the client has read the answer (`Conn.linger`): it
    /// may still be sending a body that is never read.
    linger,
};

/// Answer one request with what `f` gives.
fn answer(comptime F: type, f: F, request: *std.http.Server.Request, max_body: u64) Next {
    const Param = @typeInfo(F.Args).@"struct".field_types[0];
    const Req = @typeInfo(Param).pointer.child;
    const Resp = @typeInfo(@TypeOf(F.call)).@"fn".return_type.?;
    const gpa = rig.defaultAllocator();
    const head = request.head;
    // An expectation other than `100-continue` fails (417), and a body
    // over the limit is refused (413) before any of it is read, and
    // before `100 Continue` asks the client for it.
    if (head.expect) |e| if (!std.ascii.eqlIgnoreCase(e, "100-continue")) return refuse(request, 417, "expectation failed\n");
    if (head.content_length) |n| if (n > max_body) return refuse(request, 413, "content too large\n");
    const has_body = head.content_length != null or head.transfer_encoding == .chunked;
    // A request with both a length and chunked is read as chunked, and
    // the connection closes after it (RFC 9112 §6.1): a proxy in front
    // may have framed it by its length, and taken what follows the
    // chunks for part of its body.
    const keep_alive = head.keep_alive and !(head.content_length != null and head.transfer_encoding == .chunked);
    // The fields view the head's bytes (`view`): in the read buffer,
    // which nothing changes until the handler returns; or, when a body
    // is read, whose reads may move what the buffer holds, in one block
    // the head is copied into first.
    const bytes: []u8 = if (has_body) rig.allocSlice(u8, request.head_buffer.len) else @constCast(request.head_buffer);
    defer if (has_body) rig.freeSlice(u8, bytes);
    if (has_body) @memcpy(bytes, request.head_buffer);
    const at = @intFromPtr(head.target.ptr) - @intFromPtr(request.head_buffer.ptr);
    const target = bytes[at..][0..head.target.len];
    const q = Server.of(request).question;
    var req: Req = undefined;
    // The method's name is the program's constant text, which `view`
    // never writes: the handler only reads it.
    @field(req, "method") = view(@constCast(@tagName(head.method)));
    @field(req, "path") = view(if (q) |i| target[0..i] else target);
    @field(req, "query") = view(if (q) |i| target[i + 1 ..] else target[target.len..]);
    @field(req, "head") = view(bytes);
    @field(req, "body") = .empty;
    // The request owns only its body.
    defer rig.drop(&@field(req, "body"));
    if (has_body) {
        // Ask for the body, if the client waits to be asked, then read it.
        if (head.expect != null) request.head.expect = "100-continue";
        var buf: [4096]u8 = undefined;
        const r = request.readerExpectContinue(&buf) catch return .close;
        r.appendRemaining(gpa, &@field(req, "body").list, .limited(@intCast(max_body + 1))) catch |err| switch (err) {
            error.StreamTooLong => return refuse(request, 413, "content too large\n"),
            // The client closed, or sent a body that does not parse, or
            // took too long.
            else => return .close,
        };
    }
    // A request with no body to send never needs `100 Continue`.
    request.head.expect = null;
    const Thunk = struct {
        f: F,
        req: *const Req,
        pub fn call(t: @This(), _: @TypeOf(.{})) Resp {
            return t.f.call(.{t.req});
        }
    };
    var resp: Resp = tasks.isolateInto(Thunk{ .f = f, .req = &req }, rig.no_slot) catch return failed(request, keep_alive);
    defer rig.drop(&resp);
    // A status below 200 is an interim answer, which has no body and
    // comes before the final one, or none at all: 500.
    const code = @field(resp, "status");
    if (code < 200) return failed(request, keep_alive);
    const status: u10 = @intCast(rig.unsigned(@min(code, 999)));
    const kind = contentType(@field(resp, "type")) orelse return failed(request, keep_alive);
    respond(request, status, kind, @field(resp, "body").list.items, keep_alive) catch return .close;
    return after(request, keep_alive);
}

/// Answer 500, for a handler that panicked or gave an answer that
/// cannot be sent.
fn failed(request: *std.http.Server.Request, keep_alive: bool) Next {
    respond(request, 500, "", "internal server error\n", keep_alive) catch return .close;
    return after(request, keep_alive);
}

/// What follows an answer: the next request, or closing, once the
/// client has read the answer when it sent bytes still unread
/// (`Conn.linger`).
fn after(request: *std.http.Server.Request, keep_alive: bool) Next {
    if (keep_alive) return .next;
    return if (request.server.reader.in.bufferedLen() > 0) .linger else .close;
}

/// The content type a response's `type` (std.http's `Type`) names: a
/// named one's text, from `content_types`, made when the program is
/// compiled, or `other`'s text as written; null for an `other` holding
/// a CR, LF, or NUL, which no header line may hold.
fn contentType(t: anytype) ?[]const u8 {
    return switch (t) {
        .other => |o| if (std.mem.findAny(u8, o.text, "\r\n\x00") == null) o.text else null,
        inline else => |_, tag| @field(content_types, @tagName(tag)),
    };
}

/// The text of each content type std.http's `Type` names.
const content_types = .{
    .text = "text/plain; charset=utf-8",
    .html = "text/html; charset=utf-8",
    .json = "application/json",
    .css = "text/css; charset=utf-8",
    .js = "text/javascript; charset=utf-8",
    .csv = "text/csv; charset=utf-8",
    .xml = "application/xml",
    .svg = "image/svg+xml",
    .png = "image/png",
    .jpeg = "image/jpeg",
    .gif = "image/gif",
    .webp = "image/webp",
    .pdf = "application/pdf",
    .wasm = "application/wasm",
    .bytes = "application/octet-stream",
};

/// Answer `request` with `status` and the text `body`, and close the
/// connection once the client has read it: what remains of its body is
/// never read.
fn refuse(request: *std.http.Server.Request, status: u10, body: []const u8) Next {
    request.head.expect = null;
    respond(request, status, "", body, false) catch return .close;
    return .linger;
}

/// Answer `request` with `status`, the content type `kind` (no header
/// when empty), and `body`, keeping the connection open when `keep_alive`
/// and the client asked to: the bytes Zig's `Request.respond` writes,
/// from text made once. The status line comes from a table
/// (`statusLine`), and the length is written by `writeLength`.
fn respond(request: *std.http.Server.Request, status: u10, kind: []const u8, body: []const u8, keep_alive: bool) std.http.Server.Request.ExpectContinueError!void {
    try request.writeExpectContinue();
    const keep = discardBody(request, keep_alive);
    const out = request.server.out;
    var line: [32]u8 = undefined;
    try out.writeAll(statusLine(status, &line));
    if (!keep) try out.writeAll("connection: close\r\n");
    try writeLength(out, body.len);
    if (kind.len > 0) {
        try out.writeAll("content-type: ");
        try out.writeAll(kind);
        try out.writeAll("\r\n");
    }
    try out.writeAll("\r\n");
    if (request.head.method != .HEAD and body.len > 0) try out.writeAll(body);
    try out.flush();
}

/// Zig's `Request.discardBody`, with the body framed as RFC 9112 §6.3
/// says: whether the connection stays open, once any body the client
/// sent, unread, is read and dropped, so the next request can be read.
fn discardBody(request: *std.http.Server.Request, keep_alive: bool) bool {
    const r = &request.server.reader;
    if (keep_alive and request.head.keep_alive) switch (r.state) {
        .received_head => {
            // A request with neither a length nor chunked has no body,
            // whatever its method.
            if (request.head.content_length != null or request.head.transfer_encoding == .chunked) {
                const body = request.readerExpectContinue(&.{}) catch return false;
                _ = body.discardRemaining() catch return false;
                std.debug.assert(r.state == .ready);
            } else {
                r.state = .ready;
            }
            return true;
        },
        .body_remaining_content_length, .body_remaining_chunk_len, .body_none, .ready => return true,
        else => unreachable,
    };
    if (r.state == .received_head) r.state = .closing;
    return false;
}

/// The status line of `code`, `HTTP/1.1 200 OK\r\n`: made when the
/// program is compiled for each status Zig names, and in `buf` for any
/// other, which has no reason phrase.
fn statusLine(code: u10, buf: *[32]u8) []const u8 {
    const status: std.http.Status = @enumFromInt(code);
    return switch (status) {
        inline else => |s| comptime namedLine(s),
        _ => std.fmt.bufPrint(buf, "HTTP/1.1 {d} \r\n", .{code}) catch unreachable,
    };
}

fn namedLine(comptime s: std.http.Status) []const u8 {
    @setEvalBranchQuota(1_000_000);
    return std.fmt.comptimePrint("HTTP/1.1 {d} {s}\r\n", .{ @backingInt(s), s.phrase() orelse "" });
}

/// `content-length: N\r\n`, its digits written from the last.
fn writeLength(out: *std.Io.Writer, n: usize) std.Io.Writer.Error!void {
    const name = "content-length: ";
    var buf: [name.len + 20 + 2]u8 = undefined;
    var at: usize = buf.len - 2;
    buf[at..][0..2].* = "\r\n".*;
    var v = n;
    while (true) {
        at -= 1;
        buf[at] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
        if (v == 0) break;
    }
    at -= name.len;
    buf[at..][0..name.len].* = name.*;
    try out.writeAll(buf[at..]);
}

/// Zig's HTTP server, and what its last head held beyond Zig's `Head`:
/// where the target's `?` is, found in the one pass that reads the head
/// (`HeadScan`).
const Server = struct {
    http: std.http.Server,
    /// The target's first `?`, from the target's first byte.
    question: ?usize = null,

    fn init(in: *std.Io.Reader, out: *std.Io.Writer) Server {
        return .{ .http = .init(in, out) };
    }

    /// The `Server` of a request it received.
    fn of(request: *std.http.Server.Request) *Server {
        return @alignCast(@fieldParentPtr("http", request.server));
    }

    /// Zig's `receiveHead` and `Head.parse`, in one pass over the head as
    /// it arrives, once any empty lines before it are skipped
    /// (`empty_lines`): the request, or the error those give.
    fn receiveHead(s: *Server) HeadError!std.http.Server.Request {
        const r = &s.http.reader;
        r.trailers = &.{};
        const in = r.in;
        var scan: HeadScan = .{};
        var empty: usize = 0;
        while (true) {
            var bytes = in.buffered();
            if (scan.at == 0) {
                // Before the request line, up to `empty_lines` empty
                // lines are skipped, and a lone `\r` waits for the byte
                // after it.
                while (empty < empty_lines and std.mem.startsWith(u8, bytes, "\r\n")) : (empty += 1) {
                    in.toss(2);
                    bytes = in.buffered();
                }
                if (empty < empty_lines and bytes.len == 1 and bytes[0] == '\r') bytes = bytes[0..0];
            }
            if (scan.feed(bytes)) |len| {
                r.state = .received_head;
                in.toss(len);
                if (scan.err) |err| return err;
                s.question = scan.question;
                return .{ .server = &s.http, .head_buffer = bytes[0..len], .head = scan.made(bytes) };
            }
            if (in.bufferedLen() >= r.max_head_len) return error.HttpHeadersOversize;
            in.fillMore() catch |err| switch (err) {
                error.EndOfStream => return if (in.bufferedLen() == 0) error.HttpConnectionClosing else error.HttpRequestTruncated,
                error.ReadFailed => return error.ReadFailed,
            };
        }
    }
};

const Head = std.http.Server.Request.Head;

/// How many empty lines before a request line `receiveHead` skips: a
/// server should skip at least one (RFC 9112 §2.2), which some clients
/// send after a body, and Go's skips four bytes of them after a POST.
/// A bare `\n` is not skipped, but refused, as it is in a head.
const empty_lines = 2;

/// What reading a head gives up with: Zig's `receiveHead` and
/// `Head.parse` errors, and what `HeadScan` refuses beyond them.
const HeadError = std.http.Reader.HeadError || Head.ParseError || Refused;

/// Heads `HeadScan` refuses that Zig's `Head.parse` takes: those a proxy
/// in front of the server may read with another end, or another body.
const Refused = error{
    /// A CR, LF, or NUL that ends no line (RFC 9110 §5.5).
    HttpHeaderByteInvalid,
    /// A Transfer-Encoding whose last coding is not `chunked`, which
    /// leaves the body's end unknown (RFC 9112 §6.3).
    HttpTransferEncodingNotChunked,
};

/// One pass over a request's head as it arrives. It finds where the head
/// ends as Zig's `HeadParser` means to, at the first empty line or bare
/// `\n\n`, and reads each line, once its `\r\n` is in, as Zig's
/// `Head.parse` does: the same `Head`, or the same first error, once the
/// head ends. Beyond `Head.parse`, it refuses a CR, LF, or NUL that ends
/// no line, a Content-Length that is not digits, and a Transfer-Encoding
/// whose last coding is not `chunked` (`Refused`); and it reads a
/// Transfer-Encoding's codings named in any case, between spaces or tabs,
/// as RFC 9112 §7 says, which `Head.parse` refuses. It finds line ends,
/// CRs, NULs, and colons together, a vector of bytes at a time, and
/// keeps what it found as offsets from the head's first byte, which the
/// reader may move between feeds.
const HeadScan = struct {
    /// How many bytes are scanned.
    at: usize = 0,
    /// Where the line being scanned starts.
    line: usize = 0,
    /// Its first colon, in a header's line.
    colon: ?usize = null,
    /// How many CRs it holds: one, before its `\n`, when it ends well.
    crs: u32 = 0,
    /// Whether the line being scanned is the request line.
    first: bool = true,
    /// The request line's first `?`, then the target's, from the
    /// target's first byte.
    question: ?usize = null,
    /// The first line's error, given once the head ends: Zig's
    /// `Head.parse` reads no line past its first error.
    err: ?(Head.ParseError || Refused) = null,
    /// The head, but for its text, which is held as offsets.
    head: Head = .{
        .method = .GET,
        .target = "",
        .version = .@"HTTP/1.1",
        .expect = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .transfer_compression = .identity,
        .keep_alive = true,
    },
    target: Span = .{ .at = 0, .len = 0 },
    expect: ?Span = null,
    content_type: ?Span = null,

    const Span = struct { at: usize, len: usize };

    const vector_len = @max(std.simd.suggestVectorLength(u8) orelse 8, 8);
    const Bits = @Int(.unsigned, vector_len);
    const Vector = @Vector(vector_len, u8);

    /// Scan `bytes`, the head so far, from where the last feed stopped:
    /// the head's length, once it ends in them, or null.
    fn feed(s: *HeadScan, bytes: []const u8) ?usize {
        var at = s.at;
        while (at + vector_len <= bytes.len) : (at += vector_len) {
            const v: Vector = bytes[at..][0..vector_len].*;
            var bits: Bits = @bitCast(v == @as(Vector, @splat('\n')));
            bits |= @bitCast(v == @as(Vector, @splat('\r')));
            bits |= @bitCast(v == @as(Vector, @splat(0)));
            bits |= @bitCast(v == @as(Vector, @splat(':')));
            if (s.first) bits |= @bitCast(v == @as(Vector, @splat('?')));
            while (bits != 0) : (bits &= bits - 1) {
                if (s.mark(bytes, at + @ctz(bits))) |len| return len;
            }
        }
        while (at < bytes.len) : (at += 1) switch (bytes[at]) {
            '\n', '\r', 0, ':', '?' => if (s.mark(bytes, at)) |len| return len,
            else => {},
        };
        s.at = at;
        return null;
    }

    /// Note the `\n`, `\r`, NUL, `:`, or `?` at `i`: the head's length,
    /// if it ends there.
    fn mark(s: *HeadScan, bytes: []const u8, i: usize) ?usize {
        switch (bytes[i]) {
            ':' => if (!s.first and s.colon == null) {
                s.colon = i;
            },
            '?' => if (s.first and s.question == null) {
                s.question = i;
            },
            '\r' => s.crs +|= 1,
            0 => s.refuse(),
            else => return s.newline(bytes, i),
        }
        return null;
    }

    fn newline(s: *HeadScan, bytes: []const u8, i: usize) ?usize {
        if (i > 0 and bytes[i - 1] == '\r') {
            // A line starts after a `\n`, so this `\r` is in it, and
            // must be its only one.
            if (s.crs != 1) s.refuse();
            const end = i - 1;
            if (end == s.line and !s.first) return i + 1;
            s.read(bytes, end);
            s.line = i + 1;
            s.colon = null;
            s.crs = 0;
            return null;
        }
        // A bare `\n` is refused, and a second, `\n\n`, ends the head,
        // with no empty line.
        s.refuse();
        return if (i > 0 and bytes[i - 1] == '\n') i + 1 else null;
    }

    /// Refuse the head, unless a line before has failed.
    fn refuse(s: *HeadScan) void {
        if (s.err == null) s.err = error.HttpHeaderByteInvalid;
    }

    /// Read the line from `s.line` to `end`, as `Head.parse` does.
    fn read(s: *HeadScan, bytes: []const u8, end: usize) void {
        const first = s.first;
        s.first = false;
        if (s.err != null) return;
        if (first) {
            s.requestLine(bytes[0..end]) catch |err| {
                s.err = err;
            };
        } else s.header(bytes, end) catch |err| {
            s.err = err;
        };
    }

    fn requestLine(s: *HeadScan, line: []const u8) Head.ParseError!void {
        if (line.len < 10) return error.HttpHeadersInvalid;
        const method_end = std.mem.findScalar(u8, line, ' ') orelse return error.HttpHeadersInvalid;
        s.head.method = methodOf(line[0..method_end]) orelse return error.UnknownHttpMethod;
        // The version is the last 8 bytes, after the last space: when the
        // ninth from the end is no space, `Head.parse`'s version is not
        // 8 bytes long, or holds a space.
        const version_start = line.len - 9;
        if (line[version_start] != ' ' or version_start == method_end) return error.HttpHeadersInvalid;
        const version = std.mem.readInt(u64, line[version_start + 1 ..][0..8], .little);
        s.head.version = if (version == comptime word("HTTP/1.0"))
            .@"HTTP/1.0"
        else if (version == comptime word("HTTP/1.1"))
            .@"HTTP/1.1"
        else
            return error.HttpHeadersInvalid;
        s.head.keep_alive = s.head.version == .@"HTTP/1.1";
        s.target = .{ .at = method_end + 1, .len = version_start - method_end - 1 };
        // A method holds no `?`, nor does a version.
        if (s.question) |q| s.question = q - s.target.at;
    }

    fn header(s: *HeadScan, bytes: []const u8, end: usize) (Head.ParseError || Refused)!void {
        const start = s.line;
        if (bytes[start] == ' ' or bytes[start] == '\t') return error.HttpHeaderContinuationsUnsupported;
        const name = bytes[start .. s.colon orelse end];
        const value = if (s.colon) |c| std.mem.trim(u8, bytes[c + 1 .. end], " \t") else bytes[end..end];
        if (name.len == 0) return error.HttpHeadersInvalid;
        const value_at = @intFromPtr(value.ptr) - @intFromPtr(bytes.ptr);
        const eql = std.ascii.eqlIgnoreCase;
        // A known name by its length and first byte, then the whole name.
        const first = name[0] | 0x20;
        switch (name.len) {
            "connection".len => if (first == 'c' and eql(name, "connection")) {
                s.head.keep_alive = !eql(value, "close");
            },
            "expect".len => if (first == 'e' and eql(name, "expect")) {
                s.expect = .{ .at = value_at, .len = value.len };
            },
            "content-type".len => if (first == 'c' and eql(name, "content-type")) {
                s.content_type = .{ .at = value_at, .len = value.len };
            },
            "content-length".len => if (first == 'c' and eql(name, "content-length")) {
                if (s.head.content_length != null) return error.HttpHeadersInvalid;
                s.head.content_length = digits(value) orelse return error.InvalidContentLength;
            },
            "content-encoding".len => if (first == 'c' and eql(name, "content-encoding")) {
                if (s.head.transfer_compression != .identity) return error.HttpHeadersInvalid;
                const trimmed = std.mem.trim(u8, value, " ");
                s.head.transfer_compression = std.http.ContentEncoding.fromString(trimmed) orelse return error.HttpTransferEncodingUnsupported;
            },
            "transfer-encoding".len => if (first == 't' and eql(name, "transfer-encoding")) {
                // The codings in the order applied, as
                // `Transfer-Encoding: deflate, chunked`, each named in
                // any case between spaces or tabs (RFC 9112 §7): the
                // last must be `chunked`, which alone says where the
                // body ends.
                var iter = std.mem.splitBackwardsScalar(u8, value, ',');
                if (!eql(std.mem.trim(u8, iter.first(), " \t"), "chunked")) return error.HttpTransferEncodingNotChunked;
                if (s.head.transfer_encoding != .none) return error.HttpHeadersInvalid;
                s.head.transfer_encoding = .chunked;
                if (iter.next()) |second| {
                    const trimmed_second = std.mem.trim(u8, second, " \t");
                    const transfer = std.http.ContentEncoding.fromString(trimmed_second) orelse return error.HttpTransferEncodingUnsupported;
                    if (s.head.transfer_compression != .identity) return error.HttpHeadersInvalid;
                    s.head.transfer_compression = transfer;
                }
                if (iter.next()) |_| return error.HttpTransferEncodingUnsupported;
            },
            else => {},
        }
    }

    /// The head, its text in `bytes`.
    fn made(s: *const HeadScan, bytes: []const u8) Head {
        var head = s.head;
        head.target = bytes[s.target.at..][0..s.target.len];
        head.expect = if (s.expect) |e| bytes[e.at..][0..e.len] else null;
        head.content_type = if (s.content_type) |t| bytes[t.at..][0..t.len] else null;
        return head;
    }

    /// The number `text` writes in decimal digits alone, as a
    /// Content-Length must (RFC 9110 §8.6), or null: no sign, no `_`,
    /// and none past `u64`.
    fn digits(text: []const u8) ?u64 {
        if (text.len == 0) return null;
        var n: u64 = 0;
        for (text) |c| {
            if (c < '0' or c > '9') return null;
            n = std.math.mul(u64, n, 10) catch return null;
            n = std.math.add(u64, n, c - '0') catch return null;
        }
        return n;
    }

    /// The method `text` names, exactly, or null.
    fn methodOf(text: []const u8) ?std.http.Method {
        if (text.len > 7) return null;
        var bytes: [8]u8 = @splat(0);
        @memcpy(bytes[0..text.len], text);
        bytes[7] = @intCast(text.len);
        const w = std.mem.readInt(u64, &bytes, .little);
        inline for (@typeInfo(std.http.Method).@"enum".field_names) |name| {
            if (w == comptime methodWord(name)) return @field(std.http.Method, name);
        }
        return null;
    }

    fn methodWord(comptime name: []const u8) u64 {
        var bytes: [8]u8 = @splat(0);
        @memcpy(bytes[0..name.len], name);
        bytes[7] = name.len;
        return std.mem.readInt(u64, &bytes, .little);
    }

    fn word(comptime text: *const [8]u8) u64 {
        return std.mem.readInt(u64, text, .little);
    }
};

/// What ours and Zig's `Head.parse` give for the head `bytes`, sent
/// `step` bytes at a time into a buffer of `buffer_len` (no limit when
/// 0), past the empty lines ours skips (`afterEmptyLines`): the same
/// request, or the same error (`wantHead`), and `question` is the
/// target's first `?`; or, where the head breaks a rule Zig does not
/// keep (`breaksRule`), Zig's error or one ours alone gives (`Refused`,
/// or a length not digits).
fn expectSameHead(bytes: []const u8, step: usize, buffer_len: usize) !void {
    const gpa = std.testing.allocator;
    const len = if (buffer_len == 0) bytes.len + 1 else buffer_len;
    var out: [0]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    const head = afterEmptyLines(bytes);
    const readable = try gpa.dupe(u8, head);
    defer gpa.free(readable);
    const want = wantHead(readable, len);
    // Ours, sent `step` bytes at a time.
    const buf = try gpa.alloc(u8, len);
    defer gpa.free(buf);
    var in: std.testing.Reader = .init(buf, &.{.{ .buffer = bytes }});
    in.artificial_limit = .limited(step);
    var server: Server = .init(&in.interface, &w);
    server.http.reader.max_head_len = len;
    const got = server.receiveHead();
    const broken = breaksRule(head);
    const g = (got catch |err| {
        if (broken) switch (err) {
            error.HttpHeaderByteInvalid, error.HttpTransferEncodingNotChunked, error.InvalidContentLength => return,
            else => {},
        };
        return std.testing.expectError(err, want);
    }).head;
    try std.testing.expect(!broken);
    const h = try want;
    try std.testing.expectEqual(h.method, g.method);
    try std.testing.expectEqualStrings(h.target, g.target);
    try std.testing.expectEqual(h.version, g.version);
    try std.testing.expectEqualDeep(h.expect, g.expect);
    try std.testing.expectEqualDeep(h.content_type, g.content_type);
    try std.testing.expectEqual(h.content_length, g.content_length);
    try std.testing.expectEqual(h.transfer_encoding, g.transfer_encoding);
    try std.testing.expectEqual(h.transfer_compression, g.transfer_compression);
    try std.testing.expectEqual(h.keep_alive, g.keep_alive);
    try std.testing.expectEqual(std.mem.findScalar(u8, h.target, '?'), server.question);
}

/// `bytes` past the empty lines before a request line that ours skips,
/// up to `empty_lines` of them.
fn afterEmptyLines(bytes: []const u8) []const u8 {
    var rest = bytes;
    for (0..empty_lines) |_| {
        if (std.mem.startsWith(u8, rest, "\r\n")) rest = rest[2..];
    }
    return rest;
}

/// Where the head in `bytes` ends: after its first empty line or bare
/// `\n\n`, or null.
fn headEnd(bytes: []const u8) ?usize {
    const empty = if (std.mem.find(u8, bytes, "\r\n\r\n")) |e| e + 4 else null;
    const lflf = if (std.mem.find(u8, bytes, "\n\n")) |e| e + 2 else null;
    if (empty == null) return lflf;
    if (lflf == null) return empty;
    return @min(empty.?, lflf.?);
}

/// What Zig's `Head.parse` gives for the head in `bytes`, ending where
/// `headEnd` says, read into a buffer of `len` bytes, with the errors
/// Zig's `receiveHead` gives for a head that does not end within it.
/// Zig's own `HeadParser` is not the reference: by where the bytes fall
/// between reads and its vectors, it misses some ends (a bare `\n\n`,
/// `\n\r\n\r\n`) and finds some that are none (`\r\na\r\n`, a line of
/// one byte after a vector's worth of bytes).
fn wantHead(bytes: []u8, len: usize) HeadError!Head {
    if (headEnd(bytes)) |end| if (end <= len) return Head.parse(zigReadable(bytes[0..end]));
    if (bytes.len >= len) return error.HttpHeadersOversize;
    return if (bytes.len == 0) error.HttpConnectionClosing else error.HttpRequestTruncated;
}

/// The head `bytes`, rewritten in place so that Zig's `Head.parse` reads
/// it as ours does: in a Transfer-Encoding, a tab becomes a space, and a
/// last coding of `chunked`, in any case, lower case. Ours takes both,
/// as RFC 9112 §7 says; `Head.parse` refuses them.
fn zigReadable(bytes: []u8) []u8 {
    var at: usize = 0;
    while (std.mem.findPos(u8, bytes, at, "\r\n")) |end| : (at = end + 2) {
        const line = bytes[at..end];
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "transfer-encoding")) continue;
        const value = line[colon + 1 ..];
        std.mem.replaceScalar(u8, value, '\t', ' ');
        const last = std.mem.trim(u8, value[if (std.mem.findScalarLast(u8, value, ',')) |c| c + 1 else 0 ..], " ");
        if (std.ascii.eqlIgnoreCase(last, "chunked")) @memcpy(@constCast(last), "chunked");
    }
    return bytes;
}

/// Whether the head in `bytes`, up to its first empty line or bare
/// `\n\n`, breaks a rule that Zig's `Head.parse` does not keep and
/// `HeadScan` does: a CR, LF, or NUL that ends no line (RFC 9110 §5.5), a
/// Content-Length that is not digits (RFC 9110 §8.6), or a
/// Transfer-Encoding whose last coding is not `chunked` (RFC 9112 §6.3).
/// Written apart from `HeadScan`, plainly, to check it.
fn breaksRule(bytes: []const u8) bool {
    const head = bytes[0 .. headEnd(bytes) orelse bytes.len];
    for (head, 0..) |b, i| switch (b) {
        0 => return true,
        '\n' => if (i == 0 or head[i - 1] != '\r') return true,
        '\r' => if (i + 1 < head.len and head[i + 1] != '\n') return true,
        else => {},
    };
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.first();
    while (lines.next()) |line| {
        // A line with no colon is a name with an empty value, as
        // `Head.parse` reads it.
        const colon = std.mem.findScalar(u8, line, ':');
        const name = line[0 .. colon orelse line.len];
        const value = if (colon) |c| std.mem.trim(u8, line[c + 1 ..], " \t") else "";
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (value.len == 0) return true;
            for (value) |c| if (!std.ascii.isDigit(c)) return true;
        }
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            var codings = std.mem.splitBackwardsScalar(u8, value, ',');
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, codings.first(), " \t"), "chunked")) return true;
        }
    }
    return false;
}

/// Heads our server and Zig's read alike, valid and not, each past the
/// empty lines ours skips before it (`afterEmptyLines`), and each read
/// by Zig's `Head.parse` with a Transfer-Encoding's coding names in any
/// case (`zigReadable`).
const test_heads = [_][]const u8{
    "GET / HTTP/1.1\r\n\r\n",
    "GET /a?b=c HTTP/1.0\r\nHost: x\r\nConnection: keep-alive\r\n\r\n",
    "POST /p HTTP/1.1\r\ncontent-tYpe: text/plain\r\ncontent-Length:10\r\nexpeCt:   100-continue \r\nTRansfer-encoding:\tdeflate, chunked \r\nconnectioN:\t close \r\n\r\n",
    "PUT /p HTTP/1.1\r\nContent-Encoding: gzip\r\nNoColon\r\nSpaced \t: v : w\r\n\r\n",
    "GET http://x.y:80/a?b=c:d?e HTTP/1.1\r\nHost: x.y:80\r\nReferer: http://z/?q=1\r\n\r\n",
    "OPTIONS * HTTP/1.1\r\nexpect\r\nconnection\r\ncontent-type\r\n\r\n",
    "GET / HTTP/1.1\r\n\r\nGET /next HTTP/1.1\r\n\r\n",
    // The request line.
    "GET / HTTP/1.2\r\n\r\n",
    "GET / HTTP/2.0\r\n\r\n",
    "GET / http/1.1\r\n\r\n",
    "GET / HTTP/1.1x\r\n\r\n",
    "GET / HTTP/1.1 \r\n\r\n",
    "GET /HTTP/1.1\r\n\r\n",
    "GET  HTTP/1.1\r\n\r\n",
    "GET /\tHTTP/1.1\r\n\r\n",
    "GET/ HTTP/1.1\r\n\r\n",
    "BREW / HTTP/1.1\r\n\r\n",
    "get / HTTP/1.1\r\n\r\n",
    "CONNECTX / HTTP/1.1\r\n\r\n",
    " GET / HTTP/1.1\r\n\r\n",
    "GET / H\r\n\r\n",
    // Empty lines before the request line: up to two are skipped.
    "\r\nGET / HTTP/1.1\r\n\r\n",
    "\r\n\r\nGET / HTTP/1.1\r\n\r\n",
    "\r\n\r\n\r\nGET / HTTP/1.1\r\n\r\n",
    "\r\n\r\n",
    "\r\n\r\n\r\n",
    "\r\n",
    "\r\n\r",
    "\r",
    // Headers.
    "GET / HTTP/1.1\r\n folded\r\n\r\n",
    "GET / HTTP/1.1\r\nA: b\r\n\tfolded\r\n\r\n",
    "GET / HTTP/1.1\r\n: empty\r\n\r\n",
    "GET / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n",
    "GET / HTTP/1.1\r\nContent-Length: 1\r\ncontent-length: 2\r\n\r\n",
    "GET / HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n",
    "GET / HTTP/1.1\r\nTransfer-Encoding: chunked, chunked\r\n\r\n",
    "GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n",
    "GET / HTTP/1.1\r\nTransfer-Encoding: a, b, chunked\r\n\r\n",
    "GET / HTTP/1.1\r\nContent-Encoding: gzip\r\nContent-Encoding: gzip\r\n\r\n",
    // Coding names in any case, between spaces or tabs.
    "POST / HTTP/1.1\r\nTransfer-Encoding: Chunked\r\n\r\n",
    "POST / HTTP/1.1\r\nTransfer-Encoding: CHUNKED\r\n\r\n",
    "POST / HTTP/1.1\r\nTransfer-Encoding: gzip, Chunked\r\n\r\n",
    "POST / HTTP/1.1\r\nTransfer-Encoding: gzip,\tchunked\r\n\r\n",
    "POST / HTTP/1.1\r\nTransfer-Encoding: gzip\t,\tcHuNkEd\t\r\n\r\n",
    "POST / HTTP/1.1\r\nTransfer-Encoding: Chunked\r\nTransfer-Encoding: chunked\r\n\r\n",
    "POST / HTTP/1.1\r\nTransfer-Encoding: x, Chunked\r\n\r\n",
    // The first error, of several.
    "BREW / HTTP/1.1\r\n folded\r\n\r\n",
    // No end.
    "GET / HTTP/1.1\r\nHost: x\r\n",
    "GET / HTTP/1.1\r\nHost: x\r\n\r",
    "BREW / HTTP/1.1\r\nHost: x\r\n",
    "GET / HTTP/1.1\r\nA: b\r\n\r",
    "",
    // Ends Zig's `HeadParser` finds where there are none.
    "GET / HTTP/1.1\r\na\r\n\r\n",
    "PUT * HTTP/1.0\r\n:\r\n\r\n",
    "GET / HTTP/1.1\r\na\r\nContent-Length: 2\r\n\r\nab",
    // Lengths of digits alone.
    "POST / HTTP/1.1\r\nContent-Length: 007\r\n\r\n",
    "POST / HTTP/1.1\r\nContent-Length: 18446744073709551615\r\n\r\n",
    "POST / HTTP/1.1\r\nContent-Length: 18446744073709551616\r\n\r\n",
    "POST / HTTP/1.1\r\nTransfer-Encoding: gzip,chunked\r\n\r\n",
    "POST / HTTP/1.1\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n",
};

/// Heads that break a rule ours keeps and Zig's `Head.parse` does not
/// (`breaksRule`), each with the error ours gives.
const refused_heads = [_]struct { []const u8, HeadError }{
    // A CR, LF, or NUL that ends no line, and a bare `\n\n`.
    .{ "GET / HTTP/1.1\n\n", error.HttpHeaderByteInvalid },
    .{ "GET / HTTP/1.1\nHost: x\n\n", error.HttpHeaderByteInvalid },
    .{ "GET / HTTP/1.1\r\nHost: x\n\n", error.HttpHeaderByteInvalid },
    .{ "GET / HTTP/1.1\r\nHost: x\r\n\n", error.HttpHeaderByteInvalid },
    .{ "\n\n", error.HttpHeaderByteInvalid },
    .{ "\nGET / HTTP/1.1\r\n\r\n", error.HttpHeaderByteInvalid },
    .{ "\r\n\nGET / HTTP/1.1\r\n\r\n", error.HttpHeaderByteInvalid },
    .{ "\r\rGET / HTTP/1.1\r\n\r\n", error.HttpHeaderByteInvalid },
    .{ "GET / HTTP/1.1\r\nA: b\n\r\nC: d\r\n\r\n", error.HttpHeaderByteInvalid },
    .{ "GET /?? HTTP/1.1\r\nA: b\nc\r\nD:\r\nE:\t \r\nF: g\rh\r\n\r\n", error.HttpHeaderByteInvalid },
    .{ "GET / HTTP/1.1\r\nX: a\nTransfer-Encoding: chunked\r\n\r\n", error.HttpHeaderByteInvalid },
    .{ "GET / HTTP/1.1\r\nX: a\rb\r\n\r\n", error.HttpHeaderByteInvalid },
    .{ "GET / HTTP/1.1\r\nX: a\r\r\n\r\n", error.HttpHeaderByteInvalid },
    .{ "GET / HTTP/1.1\r\nX: a\x00b\r\n\r\n", error.HttpHeaderByteInvalid },
    .{ "GET\x00 / HTTP/1.1\r\n\r\n", error.HttpHeaderByteInvalid },
    .{ "GET /\x00 HTTP/1.1\r\n\r\n", error.HttpHeaderByteInvalid },
    .{ "GET / HTTP/1.1\nHost: x\r\n\r\n", error.HttpHeaderByteInvalid },
    .{ "GET / HTTP/1.1\r\nA: b\n\r\n\r\n", error.HttpHeaderByteInvalid },
    .{ "POST\x00\n\r\n\r\n", error.HttpHeaderByteInvalid },
    // A length not digits alone.
    .{ "QUERY /q HTTP/1.1\r\nUser-Agent: z\r\nconnectioN: Close\r\nContent-Length: +5\r\n\r\nbody", error.InvalidContentLength },
    .{ "GET / HTTP/1.1\r\nContent-Length: x\r\n\r\n", error.InvalidContentLength },
    .{ "GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n", error.InvalidContentLength },
    .{ "GET / HTTP/1.1\r\nContent-Length\r\n\r\n", error.InvalidContentLength },
    .{ "GET / HTTP/1.1\r\nContent-Length: x\r\n folded\r\n\r\n", error.InvalidContentLength },
    .{ "POST / HTTP/1.1\r\nContent-Length: 1_0\r\n\r\n", error.InvalidContentLength },
    .{ "POST / HTTP/1.1\r\nContent-Length: -0\r\n\r\n", error.InvalidContentLength },
    // A Transfer-Encoding whose last coding is not `chunked`.
    .{ "GET / HTTP/1.1\r\nTransfer-Encoding: br\r\n\r\n", error.HttpTransferEncodingNotChunked },
    .{ "GET / HTTP/1.1\r\nContent-Encoding: zstd\r\nTransfer-Encoding: gzip\r\n\r\n", error.HttpTransferEncodingNotChunked },
    .{ "POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n", error.HttpTransferEncodingNotChunked },
    .{ "POST / HTTP/1.1\r\nTransfer-Encoding: none\r\n\r\n", error.HttpTransferEncodingNotChunked },
    .{ "POST / HTTP/1.1\r\nTransfer-Encoding: chunked, gzip\r\n\r\n", error.HttpTransferEncodingNotChunked },
    .{ "POST / HTTP/1.1\r\nTransfer-Encoding: Chunked, gzip\r\n\r\n", error.HttpTransferEncodingNotChunked },
    .{ "POST / HTTP/1.1\r\nTransfer-Encoding: CHUNKED, GZIP\r\n\r\n", error.HttpTransferEncodingNotChunked },
    .{ "POST / HTTP/1.1\r\nTransfer-Encoding: chunk\r\n\r\n", error.HttpTransferEncodingNotChunked },
    .{ "POST / HTTP/1.1\r\nTransfer-Encoding: chunked;q=1\r\n\r\n", error.HttpTransferEncodingNotChunked },
};

test "receiveHead gives what Zig's Head.parse gives" {
    for (test_heads) |bytes| {
        try std.testing.expect(!breaksRule(afterEmptyLines(bytes)));
        // Whole, then a few bytes at a time, as bytes arrive.
        for ([_]usize{ bytes.len + 1, 1, 3, 17 }) |step| {
            expectSameHead(bytes, step, 0) catch |err| {
                std.debug.print("head {f}, {d} at a time\n", .{ std.zig.fmtString(bytes), step });
                return err;
            };
        }
    }
}

test "receiveHead refuses a head that breaks a rule Zig's Head.parse does not keep, with its error" {
    var out: [0]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    for (refused_heads) |case| {
        const bytes, const want = case;
        try std.testing.expect(breaksRule(afterEmptyLines(bytes)));
        for ([_]usize{ bytes.len, 1, 3, 17 }) |step| {
            var buf: [128]u8 = undefined;
            var in: std.testing.Reader = .init(&buf, &.{.{ .buffer = bytes }});
            in.artificial_limit = .limited(step);
            var server: Server = .init(&in.interface, &w);
            server.http.reader.max_head_len = buf.len;
            std.testing.expectError(want, server.receiveHead()) catch |err| {
                std.debug.print("head {f}, {d} at a time\n", .{ std.zig.fmtString(bytes), step });
                return err;
            };
        }
    }
}

test "a bare \\n\\n ends a head, which is refused, however its bytes arrive" {
    // Zig's `HeadParser` misses this one when it reads the bytes whole,
    // and `Head.parse` then takes `X`'s value as `vvvv\n\nzzzzzzzz`.
    const bytes = "GET /p HTTP/1.1\r\nX: vvvv\n\nzzzzzzzz\r\n\r\n";
    var out: [0]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    for ([_]usize{ 1, 3, 17, bytes.len }) |step| {
        var buf: [bytes.len + 1]u8 = undefined;
        var in: std.testing.Reader = .init(&buf, &.{.{ .buffer = bytes }});
        in.artificial_limit = .limited(step);
        var server: Server = .init(&in.interface, &w);
        server.http.reader.max_head_len = buf.len;
        try std.testing.expectError(error.HttpHeaderByteInvalid, server.receiveHead());
        if (step == bytes.len) try std.testing.expectEqualStrings("zzzzzzzz\r\n\r\n", in.interface.buffered());
    }
}

test "receiveHead gives what Zig's Head.parse gives, or keeps a rule it does not, on generated heads" {
    // Heads made of pieces, each read whole and a few bytes at a time,
    // with and without a limit; a fixed seed, so a failure repeats.
    const pieces = [_][]const u8{
        "GET / HTTP/1.1", "POST /p?q HTTP/1.1", "PUT * HTTP/1.0", "BREW /", " HTTP/1.1", "\r\n", "\r\n",
        "\r\n",         "\r",                 "\n",              "\x00",    ":",         " ",    "\t",
        "?",              "Host: x",            "content-length", "Content-Length: ", "transfer-encoding: ",
        "Transfer-Encoding", "connection: close", "Expect: 100-continue", "content-type: a/b", "chunked",
        "gzip, chunked", "gzip",               "none",           "10",       "+5",        "1_0",  "-0",
        "007",            ", ",                 "x",
    };
    var prng: std.Random.DefaultPrng = .init(0x9112);
    const random = prng.random();
    var buf: [512]u8 = undefined;
    for (0..4000) |_| {
        var w: std.Io.Writer = .fixed(&buf);
        if (random.uintLessThan(u8, 8) != 0) w.writeAll(pieces[random.uintLessThan(usize, 3)]) catch {};
        if (random.boolean()) w.writeAll("\r\n") catch {};
        for (0..random.uintLessThan(usize, 14)) |_| w.writeAll(pieces[random.uintLessThan(usize, pieces.len)]) catch {};
        if (random.uintLessThan(u8, 4) != 0) w.writeAll("\r\n\r\n") catch {};
        const bytes = w.buffered();
        for ([_]usize{ bytes.len + 1, 1, 2, 5, 17 }) |step| {
            for ([_]usize{ 0, 19, 33 }) |limit| {
                expectSameHead(bytes, step, limit) catch |err| {
                    std.debug.print("head {f}, {d} at a time, limit {d}\n", .{ std.zig.fmtString(bytes), step, limit });
                    return err;
                };
            }
        }
    }
}

test "receiveHead refuses a head longer than its limit" {
    // No end within the limit, then the end just past it.
    try expectSameHead("GET / HTTP/1.1\r\nHost: x\r\nA: b\r\n\r\n", 5, 24);
    try expectSameHead("GET / HTTP/1.1\r\nHost: x\r\nA: b\r\n\r\n", 5, 31);
    try expectSameHead("GET / HTTP/1.1\r\nHost: x\r\nA: b\r\n\r\n", 5, 32);
}

test "receiveHead reads heads one after another, as the reader moves them" {
    // With an empty line or two between them, as a client may send after
    // a body, and one at the end before the client closes.
    const bytes = "GET /a?x HTTP/1.1\r\nA: 1\r\n\r\n\r\nPOST /b HTTP/1.0\r\nB: 22\r\nContent-Length: 0\r\n\r\n\r\n\r\nGET /c HTTP/1.1\r\n\r\n\r\n";
    var out: [0]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    for ([_]usize{ 1, 7, bytes.len }) |step| {
        // A buffer only a little longer than the longest head, which the
        // reader rebases.
        var buf: [52]u8 = undefined;
        var in: std.testing.Reader = .init(&buf, &.{.{ .buffer = bytes }});
        in.artificial_limit = .limited(step);
        var server: Server = .init(&in.interface, &w);
        server.http.reader.max_head_len = buf.len;
        const a = try server.receiveHead();
        try std.testing.expectEqualStrings("/a?x", a.head.target);
        try std.testing.expectEqual(2, server.question);
        const b = try server.receiveHead();
        try std.testing.expectEqualStrings("/b", b.head.target);
        try std.testing.expectEqual(null, server.question);
        try std.testing.expectEqual(.@"HTTP/1.0", b.head.version);
        try std.testing.expectEqual(0, b.head.content_length);
        const c = try server.receiveHead();
        try std.testing.expectEqualStrings("/c", c.head.target);
        try std.testing.expectError(error.HttpConnectionClosing, server.receiveHead());
    }
}

test "receiveHead reads a head of many headers" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("GET / HTTP/1.1\r\n");
    for (0..80) |i| try w.print("H{d}: {d}\r\n", .{ i, i });
    try w.writeAll("\r\n");
    try expectSameHead(w.buffered(), 1000, 0);
}

test "statusLine and writeLength write what Zig's respond writes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", statusLine(200, &buf));
    try std.testing.expectEqualStrings("HTTP/1.1 418 I'm a teapot\r\n", statusLine(418, &buf));
    try std.testing.expectEqualStrings("HTTP/1.1 599 \r\n", statusLine(599, &buf));
    for ([_]usize{ 0, 7, 10, 99, 1234567, std.math.maxInt(usize) }) |n| {
        var a: [64]u8 = undefined;
        var b: [64]u8 = undefined;
        var wa: std.Io.Writer = .fixed(&a);
        var wb: std.Io.Writer = .fixed(&b);
        try writeLength(&wa, n);
        try wb.print("content-length: {d}\r\n", .{n});
        try std.testing.expectEqualStrings(wb.buffered(), wa.buffered());
    }
}

/// A String whose bytes are `bytes`, which it does not own: a
/// request's field, which the handler only reads (`?http.Request`), so
/// it never grows, moves, or drops one, and keeps no view of one past
/// its return. Its capacity is its length, so no String operation reads
/// past `bytes`; `answer` drops none of them.
fn view(bytes: []u8) rig.String {
    var t: rig.String = .empty;
    t.list.items = bytes;
    t.list.capacity = bytes.len;
    return t;
}

/// A connection's socket, as the reader and writer Zig's HTTP server
/// takes. Its buffers are held only while a request is read and
/// answered: a connection waiting for its next request holds none
/// (`fill`), so an idle connection costs its task's stack pages and a
/// few small records.
const Conn = struct {
    fd: i32,
    reg: i64,
    /// The read buffer, then the write buffer, while held: a block of
    /// the worker's (`sched.takeBlock`).
    bufs: ?*[rig.sched.block_size]u8 = null,
    settings: Settings,
    /// How long each read and write may wait (`connection`).
    limit: Limit,
    /// The deadline of every wait, which moves from wait to wait without
    /// a timer set for each (`sched.Deadline`).
    timer: rig.sched.Deadline,
    reader: std.Io.Reader,
    writer: std.Io.Writer,

    const buf_size = rig.sched.block_size / 2;

    fn init(c: *Conn, fd: i32, reg: i64, settings: Settings) void {
        c.* = .{
            .fd = fd,
            .reg = reg,
            .settings = settings,
            .limit = settings.limit(false),
            .timer = .{},
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{}, .end = 0 },
        };
    }

    fn close(c: *Conn) void {
        c.timer.stop();
        c.release();
        net_close(c.fd, c.reg);
    }

    fn hold(c: *Conn) void {
        if (c.bufs != null) return;
        const b = rig.sched.takeBlock();
        c.bufs = b;
        c.reader.buffer = b[0..buf_size];
        c.writer.buffer = b[buf_size..];
    }

    /// Give the buffers back, once nothing is in them.
    fn release(c: *Conn) void {
        const b = c.bufs orelse return;
        rig.sched.giveBlock(b);
        c.bufs = null;
        c.reader.buffer = &.{};
        c.reader.seek = 0;
        c.reader.end = 0;
        c.writer.buffer = &.{};
        c.writer.end = 0;
    }

    /// Between requests: wait, holding no buffers, until bytes come, and
    /// read them into the read buffer; false once the connection closes,
    /// fails, has waited its idle time, or the task is canceled.
    fn fill(c: *Conn) bool {
        c.limit = c.settings.limit(false);
        c.writer.flush() catch return false;
        const limit: Limit = .{ .at = if (c.limit.idle) |i| rig.sched.nowNs() + i else null, .timer = &c.timer };
        c.reader.seek = 0;
        c.reader.end = 0;
        while (true) {
            rig.checkStop() catch return false;
            const seen = edges(c.reg, rig.sched.Registration.readable);
            if (drained(c.reg, seen)) {
                c.release();
                waitFor(c.fd, c.reg, rig.sched.Registration.readable, seen, limit) catch return false;
                continue;
            }
            c.hold();
            const rc = sys.read(c.fd, c.reader.buffer.ptr, c.reader.buffer.len);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return false;
                    readCame(c.reg, seen, @intCast(rc), c.reader.buffer.len);
                    c.reader.end = @intCast(rc);
                    return true;
                },
                .AGAIN => {
                    c.release();
                    waitFor(c.fd, c.reg, rig.sched.Registration.readable, seen, limit) catch return false;
                },
                .INTR => {},
                else => return false,
            }
        }
    }

    /// Before closing with a request's body unread: say no more is
    /// coming, then read and drop what the client still sends, until it
    /// closes, for at most `linger_bytes` or `linger_ns`. Closing with
    /// bytes unread resets the connection, and a reset can throw away
    /// the answer before the client reads it. It looks every
    /// `linger_poll_ns` rather than waiting on the poller, which reports
    /// a socket shut down for writing as closed, and so always ready.
    fn linger(c: *Conn) void {
        c.writer.flush() catch return;
        _ = sys.shutdown(c.fd, posix.SHUT.WR);
        c.release();
        var buf: [4096]u8 = undefined;
        var left: usize = linger_bytes;
        var waited: i64 = 0;
        while (left > 0) {
            rig.checkStop() catch return;
            const rc = sys.read(c.fd, &buf, @min(buf.len, left));
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return;
                    left -= @intCast(rc);
                },
                .AGAIN => {
                    if (waited >= linger_ns) return;
                    rig.taskSleep(linger_poll_ns) catch return;
                    waited += linger_poll_ns;
                },
                .INTR => {},
                else => return,
            }
        }
    }

    /// Answer a head that does not parse, or that `HeadScan` refuses,
    /// 400, and close once the client has read it.
    fn refuseHead(c: *Conn) void {
        c.limit = c.settings.limit(false);
        c.writer.writeAll(bad_request) catch return;
        c.linger();
    }

    const bad_request = namedLine(.bad_request) ++ "connection: close\r\ncontent-length: 12\r\n\r\nbad request\n";

    /// What each read and write waits for: `limit`, by the connection's
    /// deadline.
    fn waits(c: *Conn) Limit {
        var l = c.limit;
        l.timer = &c.timer;
        return l;
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const c: *Conn = @alignCast(@fieldParentPtr("reader", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = readSome(c.fd, c.reg, dest, c.waits()) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        w.advance(n);
        return n;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const c: *Conn = @alignCast(@fieldParentPtr("writer", w));
        writeAll(c.fd, c.reg, w.buffer[0..w.end], c.waits()) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            writeAll(c.fd, c.reg, d, c.waits()) catch return error.WriteFailed;
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            writeAll(c.fd, c.reg, last, c.waits()) catch return error.WriteFailed;
            n += last.len;
        }
        return n;
    }
};

const net_close = close;
