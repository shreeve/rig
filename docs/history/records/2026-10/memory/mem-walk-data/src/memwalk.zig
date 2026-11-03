//! std.memwalk's snapshot (measurement only).
const std = @import("std");
const rig = @import("../runtime.zig");
const table = @import("../table.zig");
const linux = std.os.linux;

fn envGet(name: []const u8) ?[]const u8 {
    const init = rig.process.* orelse return null;
    return init.environ.getPosix(name);
}

fn openZ(path: []const u8, write: bool) ?i32 {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const flags: linux.O = if (write) .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true } else .{ .ACCMODE = .RDONLY };
    const r = linux.open(@ptrCast(&buf), flags, 0o644);
    if (linux.errno(r) != .SUCCESS) return null;
    return @intCast(r);
}

fn writeAll(fd: i32, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const r = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (linux.errno(r) != .SUCCESS or r == 0) return;
        off += r;
    }
}

fn copyFile(from: []const u8, to: []const u8) void {
    const src = openZ(from, false) orelse return;
    defer _ = linux.close(src);
    const dst = openZ(to, true) orelse return;
    defer _ = linux.close(dst);
    var buf: [65536]u8 = undefined;
    while (true) {
        const r = linux.read(src, &buf, buf.len);
        if (linux.errno(r) != .SUCCESS or r == 0) return;
        writeAll(dst, buf[0..r]);
    }
}

/// The kB value of `key:` in /proc/self/status.
fn statusKb(text: []const u8, key: []const u8) u64 {
    const at = std.mem.indexOf(u8, text, key) orelse return 0;
    var i = at + key.len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == ':')) i += 1;
    var v: u64 = 0;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) v = v * 10 + (text[i] - '0');
    return v;
}

var vec: [1 << 20]u8 = undefined;

/// The bytes resident in [p, p + len), by mincore, 4 KiB pages.
fn resident(p: usize, len: usize) u64 {
    var n: u64 = 0;
    var at = p;
    const end = p + len;
    while (at < end) {
        const chunk = @min(end - at, vec.len * 4096);
        const r = linux.syscall3(.mincore, at, chunk, @intFromPtr(&vec));
        if (linux.errno(r) != .SUCCESS) return n;
        const pages = (chunk + 4095) / 4096;
        for (vec[0..pages]) |b| n += b & 1;
        at += chunk;
    }
    return n * 4096;
}

pub fn snap_at(label: []const u8, live: i64, peak: i64) void {
    var sbuf: [8192]u8 = undefined;
    var slen: usize = 0;
    if (openZ("/proc/self/status", false)) |fd| {
        const r = linux.read(fd, &sbuf, sbuf.len);
        if (linux.errno(r) == .SUCCESS) slen = r;
        _ = linux.close(fd);
    }
    const s = sbuf[0..slen];
    var tables_res: u64 = 0;
    var tables_n: usize = 0;
    var dir_buf: [1024]u8 = undefined;
    const dir = envGet("MEMWALK_DIR");
    var tfd: ?i32 = null;
    if (dir) |d| {
        copyFile("/proc/self/smaps", std.fmt.bufPrint(&dir_buf, "{s}/{s}.smaps", .{ d, label }) catch return);
        tfd = openZ(std.fmt.bufPrint(&dir_buf, "{s}/{s}.tables", .{ d, label }) catch return, true);
    }
    if (@hasDecl(table, "memwalk_tables")) {
        tables_n = table.memwalk_count.load(.monotonic);
        for (table.memwalk_tables[0..tables_n]) |t| {
            const res = resident(t.p, t.bytes);
            tables_res += res;
            if (tfd) |fd| {
                var lb: [512]u8 = undefined;
                writeAll(fd, std.fmt.bufPrint(&lb, "{d} {d} {d} {x} {d} {s}\n", .{ res, t.size, t.n, t.p, t.bytes, t.name }) catch continue);
            }
        }
    }
    if (tfd) |fd| _ = linux.close(fd);
    if (dir) |d| if (@hasDecl(rig, "memwalkOwners")) {
        if (openZ(std.fmt.bufPrint(&dir_buf, "{s}/{s}.owners", .{ d, label }) catch return, true)) |fd| {
            rig.memwalkOwners(fd);
            _ = linux.close(fd);
        }
    };
    std.debug.print("MEMWALK {s} live={d} peak={d} tables_res={d} tables={d} VmRSS={d} VmHWM={d} RssAnon={d} RssFile={d}\n", .{ label, live, peak, tables_res, tables_n, statusKb(s, "VmRSS") * 1024, statusKb(s, "VmHWM") * 1024, statusKb(s, "RssAnon") * 1024, statusKb(s, "RssFile") * 1024 });
}
