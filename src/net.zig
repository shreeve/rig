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

/// macOS sets a socket not to block after it is made.
fn nonblocking(fd: i32) void {
    if (!darwin) return;
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    _ = std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
    _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
}

/// A fallible waiting point: fail when the task is canceled or its
/// deadline has passed.
fn stopped() rig.Stop!void {
    const t = rig.task();
    if (t.control) |c| if (c.canceled.load(.acquire)) return canceled;
    if (t.deadline) |d| if (rig.sched.nowNs() >= d) return timeout;
}

/// Wait for `fd` to be ready for `interest`: on its poller, or, outside
/// the scheduler, in `poll`.
fn waitFor(fd: i32, reg: i64, interest: u32) rig.Stop!void {
    const t = rig.task();
    if (reg != 0 and rig.sched.current() != null) {
        return switch (rig.sched.waitReady(@ptrFromInt(@as(usize, @intCast(reg))), interest, t.deadline, true)) {
            .ready => {},
            .canceled => canceled,
            .timeout => timeout,
        };
    }
    const events: i16 = if (interest == rig.sched.Registration.readable) posix.POLL.IN else posix.POLL.OUT;
    var fds = [1]posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    var ms: i32 = -1;
    if (t.deadline) |d| {
        const left = d - rig.sched.nowNs();
        if (left <= 0) return timeout;
        ms = @intCast(@min(@divTrunc(left + std.time.ns_per_ms - 1, std.time.ns_per_ms), std.math.maxInt(i32)));
    }
    const n = posix.poll(&fds, ms) catch return;
    if (n == 0) return timeout;
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
    try stopped();
    const sa = SockAddr.of(try parse(addr));
    const fd = try socket(sa.family);
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
    try waitFor(s, reg, rig.sched.Registration.writable);
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
    const s: i32 = @intCast(fd);
    try stopped();
    while (true) {
        const rc = if (darwin) sys.accept(s, null, null) else sys.accept4(s, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const c: i32 = @intCast(rc);
                nonblocking(c);
                return c;
            },
            .AGAIN => try waitFor(s, reg, rig.sched.Registration.readable),
            .INTR, .CONNABORTED => {},
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

pub fn read_from(fd: i64, reg: i64, into: *rig.String, max: i64) Error!i64 {
    const want: usize = @intCast(@max(max, 0));
    if (want == 0) return 0;
    into.list.ensureUnusedCapacity(rig.defaultAllocator(), want) catch rig.oom();
    const n = try readSome(@intCast(fd), reg, into.list.unusedCapacitySlice()[0..want]);
    into.list.items.len += n;
    return @intCast(n);
}

/// Read what comes into `dest`, once any does: how many bytes, or 0 once
/// the other end has closed.
fn readSome(s: i32, reg: i64, dest: []u8) Error!usize {
    try stopped();
    while (true) {
        const rc = sys.read(s, dest.ptr, dest.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .AGAIN => try waitFor(s, reg, rig.sched.Registration.readable),
            .INTR => {},
            else => |e| return failure(e),
        }
    }
}

pub fn write_to(fd: i64, reg: i64, bytes: []const u8) Error!void {
    const s: i32 = @intCast(fd);
    try stopped();
    var at: usize = 0;
    while (at < bytes.len) {
        const rc = sys.write(s, bytes[at..].ptr, bytes.len - at);
        switch (posix.errno(rc)) {
            .SUCCESS => at += @intCast(rc),
            .AGAIN => try waitFor(s, reg, rig.sched.Registration.writable),
            .INTR => {},
            else => |e| return failure(e),
        }
    }
}

pub fn close(fd: i64, reg: i64) void {
    if (reg != 0) rig.sched.deregister(@ptrFromInt(@as(usize, @intCast(reg))));
    _ = sys.close(@intCast(fd));
}

// -----------------------------------------------------------------------------
// The HTTP server
// -----------------------------------------------------------------------------

/// `http.serve(<listener, |req| ...)`: take connections on `listener`,
/// each a task of its own, and answer each request on them with what
/// `f` gives for it, until the call is canceled or the listener fails.
/// Each request runs isolated (`tasks.isolate`): a panic in `f` answers
/// 500, and the server goes on. The connections' tasks end before it
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
    while (true) {
        const c = try accept_on(@field(l, "fd"), @field(l, "reg"));
        server.reap();
        server.conns.append(std.heap.smp_allocator, tasks.Task(void).spawn(connection(F), .{ @as(i32, @intCast(c)), f })) catch rig.oom();
    }
}

/// A connection's task: read its requests one after another, and answer
/// each, until it closes, fails, or the task is canceled.
fn connection(comptime F: type) fn (i32, F) void {
    return struct {
        fn run(fd: i32, f: F) void {
            var c: Conn = undefined;
            c.init(fd);
            defer c.close();
            var server = std.http.Server.init(&c.reader, &c.writer);
            while (true) {
                var request = server.receiveHead() catch return;
                if (!answer(F, f, &request)) return;
            }
        }
    }.run;
}

/// Answer one request with what `f` gives; whether the connection goes
/// on.
fn answer(comptime F: type, f: F, request: *std.http.Server.Request) bool {
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
    var body: rig.String = .empty;
    if (head.content_length != null or head.transfer_encoding == .chunked) {
        var buf: [4096]u8 = undefined;
        const r = request.readerExpectNone(&buf);
        r.appendRemaining(gpa, &body.list, .limited(16 << 20)) catch {};
    }
    @field(req, "body") = body;
    defer rig.drop(&req);
    const Thunk = struct {
        f: F,
        req: *const Req,
        pub fn call(t: @This(), _: @TypeOf(.{})) Resp {
            return t.f.call(.{t.req});
        }
    };
    var resp: Resp = tasks.isolate(Thunk{ .f = f, .req = &req }) catch {
        request.respond("internal server error\n", .{ .status = .internal_server_error, .keep_alive = head.keep_alive }) catch return false;
        return head.keep_alive;
    };
    defer rig.drop(&resp);
    const status: u10 = @intCast(std.math.clamp(@field(resp, "status"), 100, 999));
    const kind = @field(resp, "type").list.items;
    const headers = [_]std.http.Header{.{ .name = "content-type", .value = kind }};
    request.respond(@field(resp, "body").list.items, .{
        .status = @enumFromInt(status),
        .keep_alive = head.keep_alive,
        .extra_headers = if (kind.len > 0) &headers else &.{},
    }) catch return false;
    return head.keep_alive;
}

/// A fresh String of `bytes`.
fn fresh(bytes: []const u8) rig.String {
    var s: rig.String = .empty;
    s.list.appendSlice(rig.defaultAllocator(), bytes) catch rig.oom();
    return s;
}

/// A connection's socket, as the reader and writer Zig's HTTP server
/// takes.
const Conn = struct {
    fd: i32,
    reg: i64,
    in_buf: [8192]u8,
    out_buf: [8192]u8,
    reader: std.Io.Reader,
    writer: std.Io.Writer,

    fn init(c: *Conn, fd: i32) void {
        c.fd = fd;
        c.reg = watch(fd);
        c.reader = .{ .vtable = &.{ .stream = stream }, .buffer = &c.in_buf, .seek = 0, .end = 0 };
        c.writer = .{ .vtable = &.{ .drain = drain }, .buffer = &c.out_buf, .end = 0 };
    }

    fn close(c: *Conn) void {
        net_close(c.fd, c.reg);
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const c: *Conn = @alignCast(@fieldParentPtr("reader", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = readSome(c.fd, c.reg, dest) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        w.advance(n);
        return n;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const c: *Conn = @alignCast(@fieldParentPtr("writer", w));
        write_to(c.fd, c.reg, w.buffer[0..w.end]) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            write_to(c.fd, c.reg, d) catch return error.WriteFailed;
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            write_to(c.fd, c.reg, last) catch return error.WriteFailed;
            n += last.len;
        }
        return n;
    }
};

const net_close = close;
