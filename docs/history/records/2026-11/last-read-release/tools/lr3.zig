// __lr.zig: the last-read census's state (lastread-zig puts it in the package; scratch, never lands).
// A ticker thread keeps `epoch` (microseconds since the program started, in units of 1024 ns) and samples
// the process's resident pages every millisecond. `touch` keeps, for each file and kind, the last epoch
// any task read it after the census began (event 1). `event` logs a mark with the task's thread id.
// `bytes` keeps each file's bytes by kind. `dump` writes it all to stderr, once, at exit.
const std = @import("std");
const linux = std.os.linux;

const MAXF: usize = 1 << 19;
const KINDS: usize = 8;
const MAXE: usize = 1 << 21;
const MAXS: usize = 1 << 20;

var last: [MAXF * KINDS]u32 = @splat(0);
// Each thread's own last reads (a checker's task stays on its worker), for the safe points of the reader itself.
const MAXT: usize = 12;
const MAXFT: usize = 1 << 17;
threadlocal var slot: i32 = -1;
var nslots: u32 = 0;
var tids: [MAXT]i32 = @splat(0);
var lastt: [MAXT * MAXFT * KINDS]u32 = @splat(0);
var maxfile: u32 = 0;
var nbytes: [MAXF * KINDS]i64 = @splat(0);
var epoch: u32 = 0;
var active: bool = false;
var t0_ns: u64 = 0;

const Ev = extern struct { e: u32, code: u32, a: u32, b: u32, tid: i32 };
var evs: [MAXE]Ev = undefined;
var nev: usize = 0;

const Sm = extern struct { e: u32, res: u32, shared: u32 };
var sms: [MAXS]Sm = undefined;
var nsm: usize = 0;
var stop: bool = false;
var started: bool = false;

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
}

fn sample() void {
    const fd_rc = linux.open("/proc/self/statm", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_rc)));
    if (fd < 0) return;
    defer _ = linux.close(fd);
    var buf: [128]u8 = undefined;
    const n: isize = @bitCast(linux.read(fd, &buf, buf.len));
    if (n <= 0) return;
    var it = std.mem.tokenizeScalar(u8, buf[0..@intCast(n)], ' ');
    _ = it.next();
    const res = std.fmt.parseInt(u32, it.next() orelse return, 10) catch return;
    const shared = std.fmt.parseInt(u32, it.next() orelse return, 10) catch return;
    if (nsm < MAXS) {
        sms[nsm] = .{ .e = @atomicLoad(u32, &epoch, .monotonic), .res = res, .shared = shared };
        nsm += 1;
    }
}

fn tick() void {
    var next_sample: u64 = 0;
    while (!@atomicLoad(bool, &stop, .acquire)) {
        const now = nowNs();
        const e: u32 = @truncate((now - t0_ns) >> 10);
        @atomicStore(u32, &epoch, e, .monotonic);
        if (now >= next_sample) {
            sample();
            next_sample = now + 1_000_000;
        }
        const req: linux.timespec = .{ .sec = 0, .nsec = 20_000 };
        _ = linux.nanosleep(&req, null);
    }
}

pub fn start() void {
    if (started) return;
    started = true;
    t0_ns = nowNs();
    const th = std.Thread.spawn(.{ .stack_size = 256 << 10 }, tick, .{}) catch return;
    th.detach();
}

pub inline fn touch(file: u32, kinds: u32) void {
    if (file == 0 or !@atomicLoad(bool, &active, .monotonic)) return;
    const e = @atomicLoad(u32, &epoch, .monotonic);
    if (slot < 0) {
        const n = @atomicRmw(u32, &nslots, .Add, 1, .monotonic);
        slot = @intCast(@min(n, MAXT - 1));
        if (n < MAXT) tids[n] = linux.gettid();
    }
    if (file > @atomicLoad(u32, &maxfile, .monotonic)) @atomicStore(u32, &maxfile, file, .monotonic);
    const base = @as(usize, @intCast(slot)) * MAXFT * KINDS;
    var k = kinds;
    while (k != 0) {
        const b: u32 = @ctz(k);
        k &= k - 1;
        const i = @as(usize, file) * KINDS + b;
        if (i < last.len and @atomicLoad(u32, &last[i], .monotonic) != e) @atomicStore(u32, &last[i], e, .monotonic);
        if (file < MAXFT and lastt[base + i] != e) lastt[base + i] = e;
    }
}

pub fn event(code: u32, a: u32, b: u32) void {
    if (code == 1) @atomicStore(bool, &active, true, .release);
    const k = @atomicRmw(usize, &nev, .Add, 1, .monotonic);
    if (k < MAXE) evs[k] = .{ .e = @atomicLoad(u32, &epoch, .monotonic), .code = code, .a = a, .b = b, .tid = linux.gettid() };
}

pub fn bytes(file: u32, kind: u32, n: i64) void {
    const i = @as(usize, file) * KINDS + kind;
    if (i < nbytes.len) nbytes[i] = n;
}

var obuf: [1 << 16]u8 = undefined;
var olen: usize = 0;

fn flush() void {
    var off: usize = 0;
    while (off < olen) {
        const r: isize = @bitCast(linux.write(2, obuf[off..olen].ptr, olen - off));
        if (r <= 0) break;
        off += @intCast(r);
    }
    olen = 0;
}

fn out(comptime fmt: []const u8, args: anytype) void {
    if (olen + 256 > obuf.len) flush();
    const s = std.fmt.bufPrint(obuf[olen..], fmt, args) catch return;
    olen += s.len;
}

fn hwm() u64 {
    const fd_rc = linux.open("/proc/self/status", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_rc)));
    if (fd < 0) return 0;
    defer _ = linux.close(fd);
    var buf: [4096]u8 = undefined;
    const n: isize = @bitCast(linux.read(fd, &buf, buf.len));
    if (n <= 0) return 0;
    const s = buf[0..@intCast(n)];
    const at = std.mem.indexOf(u8, s, "VmHWM:") orelse return 0;
    var it = std.mem.tokenizeAny(u8, s[at + 6 ..], " \t\n");
    return std.fmt.parseInt(u64, it.next() orelse return 0, 10) catch 0;
}

var dumped = false;
pub fn dump() void {
    if (dumped or !@atomicLoad(bool, &active, .monotonic)) return;
    dumped = true;
    sample();
    @atomicStore(bool, &stop, true, .release);
    out("LRT\t{d}\t{d}\t{d}\n", .{ t0_ns, @atomicLoad(u32, &epoch, .monotonic), hwm() });
    var f: usize = 0;
    while (f < MAXF) : (f += 1) {
        var k: usize = 0;
        while (k < KINDS) : (k += 1) {
            const i = f * KINDS + k;
            if (nbytes[i] != 0) out("LRB\t{d}\t{d}\t{d}\n", .{ f, k, nbytes[i] });
            if (last[i] != 0) out("LRL\t{d}\t{d}\t{d}\n", .{ f, k, last[i] });
        }
    }
    var t: usize = 0;
    while (t < @min(nslots, MAXT)) : (t += 1) {
        var g: usize = 0;
        while (g <= maxfile and g < MAXFT) : (g += 1) {
            var k2: usize = 0;
            while (k2 < KINDS) : (k2 += 1) {
                const v = lastt[t * MAXFT * KINDS + g * KINDS + k2];
                if (v != 0) out("LRM\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ t, tids[t], g, k2, v });
            }
        }
    }
    const ne = @min(nev, MAXE);
    for (evs[0..ne]) |ev| out("LRE\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ ev.e, ev.code, ev.a, ev.b, ev.tid });
    for (sms[0..@min(nsm, MAXS)]) |sm| out("LRS\t{d}\t{d}\t{d}\n", .{ sm.e, sm.res, sm.shared });
    flush();
}
