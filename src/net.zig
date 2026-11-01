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
const split = rig.split;

// Unit 0 of a split build defines every cell of this file
// (`split.cell`).
comptime {
    if (split.on and split.main) _ = .{
        lent.lock,
        lent.fds,
        lent.buffers,
        lent.next,
    };
}
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
    const one: c_int = 1;
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&one)) catch {};
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
/// HTTP server sets these for its connections (`Conn`); a call from
/// Rig sets neither.
const Limit = struct {
    at: ?i96 = null,
    idle: ?i96 = null,

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

/// Wait for `fd` to be ready for `interest`: on its poller, or, outside
/// the scheduler, in `poll`; no longer than `limit` allows.
fn waitFor(fd: i32, reg: i64, interest: u32, limit: Limit) rig.Stop!void {
    const t = rig.task();
    const deadline = limit.deadline(t.deadline);
    if (reg != 0 and rig.sched.current() != null) {
        return switch (rig.sched.waitReady(@ptrFromInt(@as(usize, @intCast(reg))), interest, deadline, true)) {
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
            else => return,
        }
    }
}

pub fn listen_on(addr: []const u8) Error!i64 {
    const sa = SockAddr.of(try parse(addr));
    const fd = try socket(sa.family);
    errdefer _ = sys.close(fd);
    const one: c_int = 1;
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one)) catch {};
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
    try waitFor(s, reg, rig.sched.Registration.writable, .{});
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
        const rc = if (darwin) sys.accept(s, null, null) else sys.accept4(s, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const c: i32 = @intCast(rc);
                nonblocking(c);
                noDelay(c);
                return c;
            },
            .AGAIN => try waitFor(s, reg, rig.sched.Registration.readable, .{}),
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
            if (n < asked or n == want) return n;
            return n + readMore(s, into, want - n);
        }
        rig.sched.giveBlock(b);
        switch (e) {
            .AGAIN => try waitFor(s, reg, rig.sched.Registration.readable, .{}),
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
        const rc = sys.read(s, dest.ptr, dest.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .AGAIN => try waitFor(s, reg, rig.sched.Registration.readable, limit),
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
        const rc = sys.write(s, bytes[at..].ptr, bytes.len - at);
        switch (posix.errno(rc)) {
            .SUCCESS => at += @intCast(rc),
            .AGAIN => try waitFor(s, reg, rig.sched.Registration.writable, limit),
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
    const v: c_int = if (on) 0 else 1;
    posix.setsockopt(@intCast(fd), posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&v)) catch {};
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
/// blocking pool (`std/file.zig`); the checker allows nothing else
/// (`Checker.ioCopy`).
pub fn copy(from: anytype, to: anytype) anyerror!i64 {
    const buf = rig.allocSlice(u8, copy_block);
    defer rig.freeSlice(u8, buf);
    var total: i64 = 0;
    while (true) {
        const n = try copyRead(from, buf);
        if (n == 0) return total;
        try copyWrite(to, buf[0..n]);
        total += @intCast(n);
    }
}

/// The size of `copy`'s blocks: 64 KiB.
const copy_block = 64 << 10;

fn copyRead(from: anytype, dest: []u8) anyerror!usize {
    if (@hasField(@TypeOf(from.*), "reg")) return readSome(@intCast(@field(from, "fd")), @field(from, "reg"), dest, .{});
    var got = try fileRead(@field(from, "fd"), dest.len);
    defer rig.dropElement(rig.String, &got);
    @memcpy(dest[0..got.list.items.len], got.list.items);
    return got.list.items.len;
}

fn copyWrite(to: anytype, bytes: []const u8) anyerror!void {
    if (@hasField(@TypeOf(to.*), "reg")) return writeAll(@intCast(@field(to, "fd")), @field(to, "reg"), bytes, .{});
    return fileWrite(@field(to, "fd"), bytes);
}

// -----------------------------------------------------------------------------
// A file's reads and writes on the blocking pool
// -----------------------------------------------------------------------------

/// Read up to `want` bytes of the file `fd` (a `file.File`'s, for it and
/// `io.copy`) on the blocking pool, as a fallible waiting point: a fresh
/// String of what it read, empty at the end of the file. The call works
/// on a duplicate of `fd` (`lend`), so a task that stops waiting and
/// closes its file leaves the call a descriptor of its own.
pub fn fileRead(fd: i64, want: usize) (rig.Stop || FileError)!rig.String {
    const token = try lend(fd);
    defer takeBack(token);
    return try (try rig.blockingStop(readLent, .{ token, want }));
}

/// Read up to `want` bytes of the file `fd` onto the end of `into`, into
/// its own buffer, on the blocking pool as `fileRead` reads: how many,
/// 0 at the end of the file. The String grows first, here, when it has
/// no room for `want` more; then it moves into the call with the
/// duplicate descriptor (`lendBuffer`), which the call fills and gives
/// back, so the bytes are read where they stay and nothing is copied. A
/// call that never runs, because a cancel or a deadline came first,
/// leaves `into` as it was; one its task stopped waiting for keeps the
/// buffer, so `into` is left empty. A String with no buffer before the
/// read is cut to what came, so a small read keeps no room for `want`.
pub fn fileReadInto(fd: i64, into: *rig.String, want: usize) (rig.Stop || FileError)!usize {
    if (want == 0) return 0;
    const bare = into.list.capacity == 0;
    _ = into.roomFor(want);
    const token = try lendBuffer(fd, into);
    defer takeBackBuffer(token, into);
    var got = try rig.blockingStop(readFilling, .{ token, want });
    // `into` is empty: the call holds its buffer, and gives it back here.
    std.mem.swap(rig.String, into, &got.buf);
    if (got.failure) |e| return e;
    if (bare) into.fit();
    return got.n;
}

/// What `readFilling` gives back: the buffer it was lent, with what it
/// read on its end, and how many bytes; or the buffer as it was, and
/// why the read failed.
const Filled = struct {
    buf: rig.String = .empty,
    n: usize = 0,
    failure: ?(rig.Stop || FileError) = null,
};

fn readFilling(token: u64, want: usize) Filled {
    const got = claimBuffer(token) orelse return .{ .failure = error.@"std.file.FileError.failed" };
    defer _ = sys.close(got.fd);
    var out: Filled = .{ .buf = got.buf };
    rig.checkStop() catch |err| {
        out.failure = err;
        return out;
    };
    const l = &out.buf.list;
    while (true) {
        const rc = sys.read(got.fd, l.items.ptr + l.items.len, want);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                out.n = @intCast(rc);
                l.items.len += out.n;
                return out;
            },
            .INTR => rig.checkStop() catch |err| {
                out.failure = err;
                return out;
            },
            else => |e| {
                out.failure = fileFailure(e);
                return out;
            },
        }
    }
}

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
/// `fileRead` reads.
pub fn fileWrite(fd: i64, bytes: []const u8) (rig.Stop || FileError)!void {
    if (fd == 1 or fd == 2) return standardWrite(fd, bytes);
    const token = try lend(fd);
    defer takeBack(token);
    return try (try rig.blockingStop(writeLent, .{ token, bytes }));
}

/// What `fileSync` writes out: the file's bytes and what the file system
/// records of it, the bytes and what reading them back needs, or the
/// whole file system that holds it.
pub const Sync = enum(u2) { all, data, fs };

/// Write out the file `fd` to its device and wait until the device has
/// it, on the blocking pool as `fileRead` reads, on a duplicate of `fd`;
/// for stdout, what `print` buffered is written out first. On macOS
/// `all` and `data` are `F_FULLFSYNC`, which also asks the drive to
/// empty its cache, falling back to `fsync` where a file system or a
/// kind of file does not take it; `fs` is Linux's `syncfs`, and on
/// other systems `sync`, which writes out every file system.
pub fn fileSync(fd: i64, how: Sync) (rig.Stop || FileError)!void {
    try fileFlush(fd);
    const token = try lend(fd);
    defer takeBack(token);
    return try (try rig.blockingStop(syncLent, .{ token, how }));
}

/// Whether the system has `syncfs`, which writes out one file system.
const has_syncfs = builtin.os.tag == .linux;

fn syncLent(token: u64, how: Sync) (rig.Stop || FileError)!void {
    const fd = claim(token) orelse return error.@"std.file.FileError.failed";
    defer _ = sys.close(fd);
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

/// The descriptors lent to calls on the blocking pool, each a duplicate
/// of a file's under a token. Whoever removes one owns it and closes it:
/// the call, once it starts (`claim`), or else its caller, once the call
/// has returned or the caller has stopped waiting (`takeBack`). So a
/// call that never runs, because a cancel or a deadline came first, and
/// one that starts after its caller stopped waiting, leave nothing open,
/// and none uses a descriptor its task may have closed and the system
/// given out again.
const lent = struct {
    var lock_var: rig.sched.SpinLock = .{};
    const lock = split.cell(&lock_var, "net.lent_lock");
    var fds_var: std.AutoHashMapUnmanaged(u64, i32) = .empty;
    const fds = split.cell(&fds_var, "net.lent_fds");
    /// The same for `fileReadInto`: each duplicate with the String it
    /// reads into, which moves with it.
    var buffers_var: std.AutoHashMapUnmanaged(u64, LentBuffer) = .empty;
    const buffers = split.cell(&buffers_var, "net.lent_buffers");
    var next_var: u64 = 1;
    const next = split.cell(&next_var, "net.lent_next");
};

const LentBuffer = struct { fd: i32, buf: rig.String };

/// A token for a duplicate of `fd` and the String `into`, which moves
/// into `lent` and leaves `into` empty.
fn lendBuffer(fd: i64, into: *rig.String) FileError!u64 {
    const dup = try duplicate(fd);
    lent.lock.lock();
    defer lent.lock.unlock();
    const token = lent.next.*;
    lent.next.* += 1;
    lent.buffers.put(std.heap.smp_allocator, token, .{ .fd = dup, .buf = into.* }) catch rig.oom();
    into.* = .empty;
    return token;
}

/// The descriptor and String lent under `token`, now the caller's, or
/// null when they were taken back already.
fn claimBuffer(token: u64) ?LentBuffer {
    lent.lock.lock();
    defer lent.lock.unlock();
    const kv = lent.buffers.fetchRemove(token) orelse return null;
    return kv.value;
}

/// Close the descriptor lent under `token` and give its String back to
/// `into`, unless a call claimed them.
fn takeBackBuffer(token: u64, into: *rig.String) void {
    var got = claimBuffer(token) orelse return;
    _ = sys.close(got.fd);
    std.mem.swap(rig.String, into, &got.buf);
    rig.dropElement(rig.String, &got.buf);
}

/// A token for a duplicate of `fd`, held in `lent`.
fn lend(fd: i64) FileError!u64 {
    const dup = try duplicate(fd);
    lent.lock.lock();
    defer lent.lock.unlock();
    const token = lent.next.*;
    lent.next.* += 1;
    lent.fds.put(std.heap.smp_allocator, token, dup) catch rig.oom();
    return token;
}

/// A duplicate of `fd`, closed on exec.
fn duplicate(fd: i64) FileError!i32 {
    while (true) {
        const rc = sys.fcntl(@intCast(fd), posix.F.DUPFD_CLOEXEC, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => {},
            else => |e| return fileFailure(e),
        }
    }
}

/// The descriptor lent under `token`, now the caller's to close, or null
/// when it was taken back already.
fn claim(token: u64) ?i32 {
    lent.lock.lock();
    defer lent.lock.unlock();
    const kv = lent.fds.fetchRemove(token) orelse return null;
    return kv.value;
}

/// Close the descriptor lent under `token`, unless a call claimed it.
fn takeBack(token: u64) void {
    if (claim(token)) |fd| _ = sys.close(fd);
}

fn readLent(token: u64, want: usize) (rig.Stop || FileError)!rig.String {
    const fd = claim(token) orelse return error.@"std.file.FileError.failed";
    defer _ = sys.close(fd);
    try rig.checkStop();
    // A read of up to `small_read` goes through the stack, so the String
    // holds only what came, and nothing at the end of the file.
    if (want <= small_read) {
        var buf: [small_read]u8 = undefined;
        while (true) {
            const rc = sys.read(fd, &buf, want);
            switch (posix.errno(rc)) {
                .SUCCESS => return fresh(buf[0..@intCast(rc)]),
                .INTR => try rig.checkStop(),
                else => |e| return fileFailure(e),
            }
        }
    }
    var s: rig.String = .empty;
    const room = s.roomFor(want);
    while (true) {
        const rc = sys.read(fd, room.ptr, want);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                s.list.items.len = @intCast(rc);
                s.fit();
                return s;
            },
            .INTR => rig.checkStop() catch |err| {
                rig.dropElement(rig.String, &s);
                return err;
            },
            else => |e| {
                rig.dropElement(rig.String, &s);
                return fileFailure(e);
            },
        }
    }
}

/// The largest read `readLent` makes through the stack: 64 KiB.
const small_read = 64 << 10;

fn writeLent(token: u64, bytes: []const u8) (rig.Stop || FileError)!void {
    const fd = claim(token) orelse return error.@"std.file.FileError.failed";
    defer _ = sys.close(fd);
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
    @"std.file.FileError.loop",
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
        .LOOP => error.@"std.file.FileError.loop",
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
/// does, so the connections it holds can close. Each request runs
/// isolated (`tasks.isolate`): a panic in `f` answers 500, and the
/// server goes on. The connections' tasks end before it
/// returns, and the listener closes then. `f` is a `rig.FnRef` taking a
/// `?http.Request` and giving an `http.Response`, whose fields the
/// runtime fills and reads by name.
pub fn serve(listener: anytype, f: anytype) anyerror!void {
    var l = listener;
    defer rig.drop(&l);
    const F = @TypeOf(f);
    const Server = struct {
        conns: std.ArrayList(tasks.Task(void)) = .empty,

        /// Free the tasks that have ended.
        fn reap(s: *@This()) void {
            var kept: usize = 0;
            for (s.conns.items) |*t| {
                if (t.control.done.load(.acquire)) {
                    t.wait();
                    continue;
                }
                s.conns.items[kept] = t.*;
                kept += 1;
            }
            s.conns.items.len = kept;
        }

        /// Cancel the connections still open, and wait for them.
        fn stop(s: *@This()) void {
            for (s.conns.items) |t| t.control.cancel();
            for (s.conns.items) |t| t.wait();
            s.conns.deinit(std.heap.smp_allocator);
        }
    };
    var server: Server = .{};
    defer server.stop();
    const settings: Settings = .read();
    var pause: i64 = accept_pause_ns;
    while (true) {
        const c = try acceptOne(@intCast(@field(l, "fd")), @field(l, "reg")) orelse {
            server.reap();
            try rig.taskSleep(pause);
            pause = @min(pause * 2, accept_pause_max_ns);
            continue;
        };
        pause = accept_pause_ns;
        server.reap();
        server.conns.append(std.heap.smp_allocator, tasks.Task(void).spawn(connection(F), .{ @as(i32, @intCast(c)), f, settings })) catch rig.oom();
    }
}

/// A connection's task: read its requests one after another, and answer
/// each, until it closes, fails, waits too long (`Settings`), or the
/// task is canceled.
fn connection(comptime F: type) fn (i32, F, Settings) void {
    return struct {
        fn run(fd: i32, f: F, settings: Settings) void {
            var c: Conn = undefined;
            c.init(fd, settings);
            defer c.close();
            var server = std.http.Server.init(&c.reader, &c.writer);
            // `init` takes the read buffer's size, which is held later.
            server.reader.max_head_len = Conn.buf_size;
            while (true) {
                if (c.reader.bufferedLen() == 0 and !c.fill()) return;
                c.limit = settings.limit(true);
                var request = server.receiveHead() catch return;
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
    const target = head.target;
    const q = std.mem.findScalar(u8, target, '?');
    var req: Req = undefined;
    @field(req, "method") = fresh(@tagName(head.method));
    @field(req, "path") = fresh(if (q) |i| target[0..i] else target);
    @field(req, "query") = fresh(if (q) |i| target[i + 1 ..] else "");
    @field(req, "head") = fresh(request.head_buffer);
    @field(req, "body") = .empty;
    defer rig.drop(&req);
    // An expectation other than `100-continue` fails (417), and a body
    // over the limit is refused (413) before any of it is read, and
    // before `100 Continue` asks the client for it.
    if (head.expect) |e| if (!std.ascii.eqlIgnoreCase(e, "100-continue")) return refuse(request, .expectation_failed, "expectation failed\n");
    if (head.content_length) |n| if (n > max_body) return refuse(request, .payload_too_large, "content too large\n");
    if (head.content_length != null or head.transfer_encoding == .chunked) {
        // Ask for the body, if the client waits to be asked, then read it.
        if (head.expect != null) request.head.expect = "100-continue";
        var buf: [4096]u8 = undefined;
        const r = request.readerExpectContinue(&buf) catch return .close;
        r.appendRemaining(gpa, &@field(req, "body").list, .limited(@intCast(max_body + 1))) catch |err| switch (err) {
            error.StreamTooLong => return refuse(request, .payload_too_large, "content too large\n"),
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
    var resp: Resp = tasks.isolate(Thunk{ .f = f, .req = &req }) catch {
        request.respond("internal server error\n", .{ .status = .internal_server_error, .keep_alive = head.keep_alive }) catch return .close;
        return if (head.keep_alive) .next else .close;
    };
    defer rig.drop(&resp);
    const status: u10 = @intCast(rig.unsigned(std.math.clamp(@field(resp, "status"), 100, 999)));
    const kind = @field(resp, "type").list.items;
    const headers = [_]std.http.Header{.{ .name = "content-type", .value = kind }};
    request.respond(@field(resp, "body").list.items, .{
        .status = @enumFromInt(status),
        .keep_alive = head.keep_alive,
        .extra_headers = if (kind.len > 0) &headers else &.{},
    }) catch return .close;
    return if (head.keep_alive) .next else .close;
}

/// Answer `request` with `status` and the text `body`, and close the
/// connection once the client has read it: what remains of its body is
/// never read.
fn refuse(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) Next {
    request.head.expect = null;
    request.respond(body, .{ .status = status, .keep_alive = false }) catch return .close;
    return .linger;
}

/// A fresh String of `bytes`.
fn fresh(bytes: []const u8) rig.String {
    return .ofBytes(bytes);
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
    reader: std.Io.Reader,
    writer: std.Io.Writer,

    const buf_size = rig.sched.block_size / 2;

    fn init(c: *Conn, fd: i32, settings: Settings) void {
        c.* = .{
            .fd = fd,
            .reg = watch(fd),
            .settings = settings,
            .limit = settings.limit(false),
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{}, .end = 0 },
        };
    }

    fn close(c: *Conn) void {
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
        const limit: Limit = .{ .at = if (c.limit.idle) |i| rig.sched.nowNs() + i else null };
        c.hold();
        c.reader.seek = 0;
        c.reader.end = 0;
        while (true) {
            rig.checkStop() catch return false;
            const rc = sys.read(c.fd, c.reader.buffer.ptr, c.reader.buffer.len);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return false;
                    c.reader.end = @intCast(rc);
                    return true;
                },
                .AGAIN => {
                    c.release();
                    waitFor(c.fd, c.reg, rig.sched.Registration.readable, limit) catch return false;
                    c.hold();
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

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const c: *Conn = @alignCast(@fieldParentPtr("reader", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = readSome(c.fd, c.reg, dest, c.limit) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        w.advance(n);
        return n;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const c: *Conn = @alignCast(@fieldParentPtr("writer", w));
        writeAll(c.fd, c.reg, w.buffer[0..w.end], c.limit) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            writeAll(c.fd, c.reg, d, c.limit) catch return error.WriteFailed;
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            writeAll(c.fd, c.reg, last, c.limit) catch return error.WriteFailed;
            n += last.len;
        }
        return n;
    }
};

const net_close = close;
