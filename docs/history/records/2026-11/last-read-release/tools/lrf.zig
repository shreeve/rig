// __lr.zig: the last-read census's state (lastread-zig puts it in the package; scratch, never lands).
// A ticker thread keeps `epoch` (microseconds since the program started, in units of 1024 ns) and samples
// the process's resident pages every millisecond. `touch` keeps, for each file and kind, the last epoch
// any task read it after the census began (event 1). `event` logs a mark with the task's thread id.
// `bytes` keeps each file's bytes by kind. `dump` writes it all to stderr, once, at exit.
const std = @import("std");
const linux = std.os.linux;
const astm = @import("ast.zig");

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

// The floors' replay (LR_FLOOR=table): files released in groups, a group once its pending count (checked files
// left, groups that reach it not yet done) reaches 0; a released file's tree, positions, text, names and binding
// overwritten with 0xA5 (as its bits say), and any later hooked read of a released kind counted as a violation.
var ptrs: [MAXF]?*anyopaque = @splat(null);
var bptrs: [MAXF]?*anyopaque = @splat(null);
var floor_path: [512]u8 = undefined;
var floor_len: usize = 0;
var poison_mask: u8 = 63;
threadlocal var prev_file: u32 = 0;
var flooring: bool = false;
var fl_ng: usize = 0;
var fl_pending: []i64 = &.{};
var fl_done: []bool = &.{};
var fl_files_start: []u32 = &.{};
var fl_files: []u32 = &.{};
var fl_edges_start: []u32 = &.{};
var fl_edges: []u32 = &.{};
var fl_group: [MAXF]i32 = @splat(-1);
var fl_bits: [MAXF]u8 = @splat(0);
var fl_checked: [MAXF]bool = @splat(false);
var released: [MAXF]u8 = @splat(0);
var fl_done_file: [MAXF]bool = @splat(false);
var lk: u32 = 0;
var n_rel_groups: u64 = 0;
var n_rel_files: u64 = 0;
var n_viol: u64 = 0;
const Viol = extern struct { e: u32, file: u32, bits: u32, tid: i32, cur: u32, nf: u32, frames: [24]usize };
var viols: [64]Viol = undefined;
threadlocal var cur_file: u32 = 0;
var stack: []u32 = &.{};

fn lock() void {
    while (@cmpxchgWeak(u32, &lk, 0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlock() void {
    @atomicStore(u32, &lk, 0, .release);
}

pub fn regbind(p: *anyopaque, file: u32) void {
    if (file < MAXF) bptrs[file] = p;
}

fn finishFile(c: u32) void {
    lock();
    defer unlock();
    if (c < MAXF and !fl_done_file[c]) {
        fl_done_file[c] = true;
        const g = fl_group[c];
        if (g >= 0 and fl_checked[c]) {
            const gi: usize = @intCast(g);
            fl_pending[gi] -= 1;
            if (fl_pending[gi] == 0 and !fl_done[gi]) releaseGroup(@intCast(gi));
        }
    }
}

fn releaseGroup(g0: u32) void {
    var sp: usize = 0;
    stack[sp] = g0;
    sp += 1;
    fl_done[g0] = true;
    while (sp > 0) {
        sp -= 1;
        const g = stack[sp];
        n_rel_groups += 1;
        for (fl_files[fl_files_start[g]..fl_files_start[g + 1]]) |c| {
            const bits = fl_bits[c];
            if (bits == 0) continue;
            const pb = bits & poison_mask;
            if (pb & 15 != 0) if (ptrs[c]) |ap| astm.__lr_poison(ap, pb & 15);
            if (pb & 16 != 0) if (bptrs[c]) |bp| astm.__lr_poison_binding(bp);
            @atomicStore(u8, &released[c], bits, .release);
            n_rel_files += 1;
        }
        for (fl_edges[fl_edges_start[g]..fl_edges_start[g + 1]]) |h| {
            fl_pending[h] -= 1;
            if (fl_pending[h] == 0 and !fl_done[h]) {
                fl_done[h] = true;
                stack[sp] = h;
                sp += 1;
            }
        }
    }
}

fn loadFloor() void {
    var path: [513]u8 = undefined;
    @memcpy(path[0..floor_len], floor_path[0..floor_len]);
    path[floor_len] = 0;
    const fd_rc = linux.open(@ptrCast(&path), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_rc)));
    if (fd < 0) return;
    defer _ = linux.close(fd);
    const A = std.heap.page_allocator;
    const cap: usize = 256 << 20;
    const mem = A.alloc(u8, cap) catch return;
    var len: usize = 0;
    while (len < cap) {
        const r: isize = @bitCast(linux.read(fd, mem[len..].ptr, cap - len));
        if (r <= 0) break;
        len += @intCast(r);
    }
    // G ngroups nedges / P g pending / E g h (sorted by g) / F census group bits checked (sorted by group)
    var lines = std.mem.tokenizeScalar(u8, mem[0..len], '\n');
    var ne: usize = 0;
    var nfe: usize = 0;
    var ei: usize = 0;
    var fi: usize = 0;
    var last_eg: usize = 0;
    var last_fg: usize = 0;
    while (lines.next()) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const tag = it.next() orelse continue;
        const a = std.fmt.parseInt(i64, it.next() orelse continue, 10) catch continue;
        const b = std.fmt.parseInt(i64, it.next() orelse "0", 10) catch 0;
        if (tag[0] == 'G') {
            fl_ng = @intCast(a);
            ne = @intCast(b);
            const nf = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
            nfe = nf;
            fl_pending = A.alloc(i64, fl_ng) catch return;
            fl_done = A.alloc(bool, fl_ng) catch return;
            fl_edges_start = A.alloc(u32, fl_ng + 1) catch return;
            fl_files_start = A.alloc(u32, fl_ng + 1) catch return;
            fl_edges = A.alloc(u32, ne) catch return;
            fl_files = A.alloc(u32, nf) catch return;
            stack = A.alloc(u32, fl_ng + 1) catch return;
            @memset(fl_done, false);
            @memset(fl_edges_start, 0);
            @memset(fl_files_start, 0);
        } else if (tag[0] == 'P') {
            fl_pending[@intCast(a)] = b;
        } else if (tag[0] == 'E') {
            const g: usize = @intCast(a);
            while (last_eg < g) : (last_eg += 1) fl_edges_start[last_eg + 1] = @intCast(ei);
            fl_edges[ei] = @intCast(b);
            ei += 1;
        } else if (tag[0] == 'F') {
            const c: usize = @intCast(a);
            const bits = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
            const checked = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
            fl_bits[c] = bits;
            fl_checked[c] = checked != 0;
            fl_group[c] = @intCast(b);
            if (b >= 0) {
                const g: usize = @intCast(b);
                while (last_fg < g) : (last_fg += 1) fl_files_start[last_fg + 1] = @intCast(fi);
                fl_files[fi] = @intCast(c);
                fi += 1;
            }
        }
    }
    while (last_eg < fl_ng) : (last_eg += 1) fl_edges_start[last_eg + 1] = @intCast(ei);
    while (last_fg < fl_ng) : (last_fg += 1) fl_files_start[last_fg + 1] = @intCast(fi);
    flooring = fl_ng > 0;
}

fn readEnv() void {
    const fd_rc = linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_rc)));
    if (fd < 0) return;
    defer _ = linux.close(fd);
    var buf: [65536]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const r: isize = @bitCast(linux.read(fd, buf[len..].ptr, buf.len - len));
        if (r <= 0) break;
        len += @intCast(r);
    }
    var it = std.mem.tokenizeScalar(u8, buf[0..len], 0);
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv, "LR_FLOOR_MASK=")) {
            poison_mask = std.fmt.parseInt(u8, kv[14..], 10) catch 63;
        } else if (std.mem.startsWith(u8, kv, "LR_FLOOR=")) {
            const v = kv[9..];
            floor_len = @min(v.len, floor_path.len);
            @memcpy(floor_path[0..floor_len], v[0..floor_len]);
        }
    }
}
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
    readEnv();
    const th = std.Thread.spawn(.{ .stack_size = 256 << 10 }, tick, .{}) catch return;
    th.detach();
}

pub inline fn touchp(p: *anyopaque, file: u32, kinds: u32) void {
    if (file != 0 and file < MAXF and ptrs[file] == null) ptrs[file] = p;
    touch(file, kinds);
}

pub fn touch(file: u32, kinds: u32) void {
    if (file == 0 or !@atomicLoad(bool, &active, .monotonic)) return;
    const e = @atomicLoad(u32, &epoch, .monotonic);
    if (flooring and file < MAXF) {
        const rb = @atomicLoad(u8, &released[file], .acquire) & @as(u8, @truncate(kinds));
        if (rb != 0) {
            const k = @atomicRmw(u64, &n_viol, .Add, 1, .monotonic);
            if (k < viols.len) {
                var v: Viol = .{ .e = e, .file = file, .bits = rb, .tid = linux.gettid(), .cur = cur_file, .nf = 0, .frames = @splat(0) };
                // the frame-pointer chain (a RIG_FRAME_POINTERS=1 build)
                var fp: usize = @frameAddress();
                while (v.nf < v.frames.len and fp != 0 and fp % 8 == 0) {
                    const next = @as(*const usize, @ptrFromInt(fp)).*;
                    const ra = @as(*const usize, @ptrFromInt(fp + 8)).*;
                    if (ra == 0) break;
                    v.frames[v.nf] = ra;
                    v.nf += 1;
                    if (next <= fp or next - fp > (1 << 24)) break;
                    fp = next;
                }
                viols[k] = v;
            }
        }
    }
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
    if (code == 1) {
        if (floor_len > 0) loadFloor();
        @atomicStore(bool, &active, true, .release);
    }
    if (code == 10) {
        if (flooring and prev_file != 0) finishFile(prev_file);
        prev_file = 0;
        cur_file = a + 1;
    }
    if (code == 11) {
        cur_file = 0;
        // done once its diagnostics are taken: at the thread's next check, its group's end, or the pass's end
        if (flooring) prev_file = a + 1;
    }
    if (flooring and (code == 41 or code == 31) and prev_file != 0) {
        finishFile(prev_file);
        prev_file = 0;
    }
    if (flooring and code == 30) {
        lock();
        var g: usize = 0;
        while (g < fl_ng) : (g += 1) {
            if (fl_pending[g] == 0 and !fl_done[g]) releaseGroup(@intCast(g));
        }
        unlock();
    }
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

fn mapsLine() void {
    const fd_rc = linux.open("/proc/self/maps", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_rc)));
    if (fd < 0) return;
    defer _ = linux.close(fd);
    var buf: [4096]u8 = undefined;
    const n: isize = @bitCast(linux.read(fd, &buf, buf.len));
    if (n <= 0) return;
    const line_end = std.mem.indexOfScalar(u8, buf[0..@intCast(n)], '\n') orelse return;
    out("LRMAP\t{s}\n", .{buf[0..line_end]});
}

var dumped = false;
pub fn dump() void {
    if (dumped or !@atomicLoad(bool, &active, .monotonic)) return;
    dumped = true;
    sample();
    @atomicStore(bool, &stop, true, .release);
    out("LRT\t{d}\t{d}\t{d}\n", .{ t0_ns, @atomicLoad(u32, &epoch, .monotonic), hwm() });
    if (flooring) {
        out("LRFL\t{d}\t{d}\t{d}\t{d}\n", .{ fl_ng, n_rel_groups, n_rel_files, n_viol });
        for (viols[0..@min(n_viol, viols.len)]) |v| {
            out("LRV\t{d}\t{d}\t{d}\t{d}\t{d}\t", .{ v.e, v.file, v.bits, v.tid, v.cur });
            for (v.frames[0..v.nf]) |ra| out("{x},", .{ra});
            out("\n", .{});
        }
        mapsLine();
    }
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
