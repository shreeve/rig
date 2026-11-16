//! The Zig ceiling for bench/net's loopback round trips (macOS, kqueue):
//! the same work as bench/net/net.rig, written as fast as Zig allows, in
//! several shapes. Prints `NAME NS CHECK` as the bench does.
//!
//!   ceiling MODE [threads]
//!     pp1      pingpong on one thread: both ends on one kqueue
//!     pp2      pingpong on two threads, each end on its own kqueue
//!     pp2b     pingpong on two threads, blocking sockets, no kqueue
//!     echo1    echo on one thread: 200 sockets on one kqueue
//!     echoN T  echo on T threads, each with its own kqueue, each thread
//!              owning whole connections (both ends)
//!     echoS T  echo on 2T threads: T own the clients' ends, T the servers'
const std = @import("std");
const c = std.c;

const PING = 20000;
const ECHO_CONNS = 100;
const ECHO_TRIPS = 1000;
const SIZE = 64;

fn now() i128 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn nonblocking(fd: i32) void {
    const flags = c.fcntl(fd, c.F.GETFL);
    _ = c.fcntl(fd, c.F.SETFL, flags | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
}

fn noDelay(fd: i32) void {
    const one: c_int = 1;
    _ = c.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(c_int));
}

const Listener = struct {
    fd: i32,
    addr: c.sockaddr.in,

    fn open() Listener {
        const fd = c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        const one: c_int = 1;
        _ = c.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(c_int));
        var a: c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (c.bind(fd, @ptrCast(&a), @sizeOf(c.sockaddr.in)) != 0) @panic("bind");
        if (c.listen(fd, 1024) != 0) @panic("listen");
        var len: c.socklen_t = @sizeOf(c.sockaddr.in);
        _ = c.getsockname(fd, @ptrCast(&a), &len);
        return .{ .fd = fd, .addr = a };
    }

    /// A connected pair: the client's end and the server's.
    fn pair(l: *const Listener, blocking: bool) [2]i32 {
        const cl = c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (c.connect(cl, @ptrCast(&l.addr), @sizeOf(c.sockaddr.in)) != 0) @panic("connect");
        const sv = c.accept(l.fd, null, null);
        if (sv < 0) @panic("accept");
        noDelay(cl);
        noDelay(sv);
        if (!blocking) {
            nonblocking(cl);
            nonblocking(sv);
        }
        return .{ cl, sv };
    }
};

fn kq() i32 {
    return c.kqueue();
}

/// Whether each socket is watched for writing too, as Rig's poller does.
var watch_write = false;

fn watchRead(q: i32, fd: i32, tag: usize) void {
    const evs = [2]c.Kevent{
        .{ .ident = @intCast(fd), .filter = c.EVFILT.READ, .flags = c.EV.ADD | c.EV.CLEAR, .fflags = 0, .data = 0, .udata = tag },
        .{ .ident = @intCast(fd), .filter = c.EVFILT.WRITE, .flags = c.EV.ADD | c.EV.CLEAR, .fflags = 0, .data = 0, .udata = tag },
    };
    var none: [1]c.Kevent = undefined;
    _ = c.kevent(q, &evs, if (watch_write) 2 else 1, &none, 0, null);
}

/// Read once; -1 when it would block.
inline fn tryRead(fd: i32, buf: []u8) isize {
    const rc = c.read(fd, buf.ptr, buf.len);
    if (rc < 0) {
        if (std.posix.errno(rc) == .AGAIN) return -1;
        @panic("read");
    }
    return rc;
}

inline fn writeAll(fd: i32, buf: []const u8) void {
    var at: usize = 0;
    while (at < buf.len) {
        const rc = c.write(fd, buf[at..].ptr, buf.len - at);
        if (rc < 0) @panic("write");
        at += @intCast(rc);
    }
}

/// Block in `q` until one event.
inline fn waitOne(q: i32) void {
    var ev: [1]c.Kevent = undefined;
    _ = c.kevent(q, &ev, 0, &ev, 1, null);
}

var msg: [SIZE]u8 = @splat('x');
/// Whether a short read counts as drained: the next read waits for an event first.
var skip = false;

// ---------------------------------------------------------------- pingpong

fn pp1() void {
    const l = Listener.open();
    const p = l.pair(false);
    const q = kq();
    watchRead(q, p[0], 0);
    watchRead(q, p[1], 1);
    var buf: [4096]u8 = undefined;
    var back: i64 = 0;
    var echoed: i64 = 0;
    const t = now();
    for (0..PING) |_| {
        writeAll(p[0], &msg);
        // server
        if (skip) waitOne(q);
        while (true) {
            const n = tryRead(p[1], &buf);
            if (n > 0) {
                echoed += n;
                writeAll(p[1], buf[0..@intCast(n)]);
                break;
            }
            waitOne(q);
        }
        // client
        var got: usize = 0;
        if (skip) waitOne(q);
        while (got < SIZE) {
            const n = tryRead(p[0], buf[got..]);
            if (n > 0) got += @intCast(n) else waitOne(q);
        }
        back += SIZE;
    }
    const ns = now() - t;
    out("pingpong", ns, back + echoed);
}

fn serverLoop(fd: i32, use_kq: bool) void {
    const q = if (use_kq) kq() else -1;
    if (use_kq) watchRead(q, fd, 0);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = tryRead(fd, &buf);
        if (n == 0) return;
        if (n < 0) {
            waitOne(q);
            continue;
        }
        writeAll(fd, buf[0..@intCast(n)]);
        if (skip and n < buf.len) waitOne(q);
    }
}

fn pp2(use_kq: bool) void {
    const l = Listener.open();
    const p = l.pair(!use_kq);
    const th = std.Thread.spawn(.{}, serverLoop, .{ p[1], use_kq }) catch @panic("spawn");
    const q = if (use_kq) kq() else -1;
    if (use_kq) watchRead(q, p[0], 0);
    var buf: [4096]u8 = undefined;
    var back: i64 = 0;
    const t = now();
    for (0..PING) |_| {
        writeAll(p[0], &msg);
        var got: usize = 0;
        if (skip and use_kq) waitOne(q);
        while (got < SIZE) {
            const n = tryRead(p[0], buf[got..]);
            if (n > 0) got += @intCast(n) else waitOne(q);
        }
        back += SIZE;
    }
    const ns = now() - t;
    _ = c.close(p[0]);
    th.join();
    out("pingpong", ns, back * 2);
}

// ---------------------------------------------------------------- echo

const End = struct {
    fd: i32,
    client: bool,
    left: u32 = ECHO_TRIPS,
    got: u32 = 0,
    total: i64 = 0,
};

/// Run the ends given to completion on one kqueue: clients write, read the
/// echo, and write again; servers echo. Returns the bytes moved.
fn loop(ends: []End) i64 {
    const q = kq();
    var clients: usize = 0;
    for (ends, 0..) |*e, i| {
        watchRead(q, e.fd, i);
        if (e.client) clients += 1;
    }
    for (ends) |*e| if (e.client) writeAll(e.fd, &msg);
    var buf: [4096]u8 = undefined;
    var evs: [256]c.Kevent = undefined;
    var done: usize = 0;
    var sum: i64 = 0;
    while (done < clients) {
        const n = c.kevent(q, &evs, 0, &evs, evs.len, null);
        for (evs[0..@intCast(n)]) |ev| {
            const e = &ends[ev.udata];
            while (true) {
                const r = tryRead(e.fd, &buf);
                if (r <= 0) break;
                e.total += r;
                if (!e.client) {
                    writeAll(e.fd, buf[0..@intCast(r)]);
                    if (skip and r < buf.len) break;
                    continue;
                }
                e.got += @intCast(r);
                if (e.got >= SIZE) {
                    e.got -= SIZE;
                    e.left -= 1;
                    if (e.left == 0) {
                        done += 1;
                        break;
                    }
                    writeAll(e.fd, &msg);
                    if (skip) break;
                }
            }
        }
    }
    for (ends) |e| sum += e.total;
    return sum;
}

/// Servers' ends only, until each sees its client's close.
fn serveLoop(ends: []End) i64 {
    const q = kq();
    for (ends, 0..) |*e, i| watchRead(q, e.fd, i);
    var buf: [4096]u8 = undefined;
    var evs: [256]c.Kevent = undefined;
    var open_: usize = ends.len;
    var sum: i64 = 0;
    while (open_ > 0) {
        const n = c.kevent(q, &evs, 0, &evs, evs.len, null);
        for (evs[0..@intCast(n)]) |ev| {
            const e = &ends[ev.udata];
            if (e.left == 0) continue;
            while (true) {
                const r = tryRead(e.fd, &buf);
                if (r < 0) break;
                if (r == 0) {
                    e.left = 0;
                    open_ -= 1;
                    break;
                }
                e.total += r;
                writeAll(e.fd, buf[0..@intCast(r)]);
                if (skip and r < buf.len) break;
            }
        }
    }
    for (ends) |e| sum += e.total;
    return sum;
}

var results: [64]i64 = @splat(0);

fn runLoop(ends: []End, slot: usize) void {
    results[slot] = loop(ends);
}

fn runServe(ends: []End, slot: usize) void {
    results[slot] = serveLoop(ends);
}

fn echo(threads: usize, split: bool) void {
    const l = Listener.open();
    var all: [2 * ECHO_CONNS]End = undefined;
    // Whole connections per thread: client then server, side by side.
    for (0..ECHO_CONNS) |i| {
        const p = l.pair(false);
        if (split) {
            all[i] = .{ .fd = p[0], .client = true };
            all[ECHO_CONNS + i] = .{ .fd = p[1], .client = false };
        } else {
            all[2 * i] = .{ .fd = p[0], .client = true };
            all[2 * i + 1] = .{ .fd = p[1], .client = false };
        }
    }
    var ths: [64]std.Thread = undefined;
    const t = now();
    if (!split) {
        const per = 2 * ECHO_CONNS / threads;
        for (0..threads) |k| ths[k] = std.Thread.spawn(.{}, runLoop, .{ all[k * per .. (k + 1) * per], k }) catch @panic("spawn");
        for (0..threads) |k| ths[k].join();
    } else {
        const per = ECHO_CONNS / threads;
        for (0..threads) |k| ths[threads + k] = std.Thread.spawn(.{}, runServe, .{ all[ECHO_CONNS + k * per .. ECHO_CONNS + (k + 1) * per], threads + k }) catch @panic("spawn");
        for (0..threads) |k| ths[k] = std.Thread.spawn(.{}, runLoop, .{ all[k * per .. (k + 1) * per], k }) catch @panic("spawn");
        for (0..threads) |k| ths[k].join();
    }
    const ns = now() - t;
    if (split) for (all[0..ECHO_CONNS]) |e| {
        _ = c.close(e.fd);
    };
    if (split) for (0..threads) |k| ths[threads + k].join();
    var sum: i64 = 0;
    for (results[0 .. 2 * threads]) |r| sum += r;
    out("echo", ns, sum);
}

fn out(name: []const u8, ns: i128, check: i64) void {
    var b: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{s} {d} {d}\n", .{ name, ns, check }) catch unreachable;
    _ = c.write(1, s.ptr, s.len);
}

pub fn main(init: std.process.Init) void {
    var it = init.minimal.args.iterate();
    _ = it.next();
    var mode: []const u8 = it.next() orelse "pp1";
    if (mode[mode.len - 1] == 'w') {
        watch_write = true;
        mode = mode[0 .. mode.len - 1];
    }
    if (mode[mode.len - 1] == '+') {
        skip = true;
        mode = mode[0 .. mode.len - 1];
    }
    const n: usize = if (it.next()) |a| std.fmt.parseInt(usize, a, 10) catch 1 else 1;
    if (std.mem.eql(u8, mode, "pp1")) pp1() else if (std.mem.eql(u8, mode, "pp2")) pp2(true) else if (std.mem.eql(u8, mode, "pp2b")) pp2(false) else if (std.mem.eql(u8, mode, "echo1")) echo(1, false) else if (std.mem.eql(u8, mode, "echoN")) echo(n, false) else if (std.mem.eql(u8, mode, "echoS")) echo(n, true) else @panic("mode");
}
