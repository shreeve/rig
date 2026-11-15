//! A small multi-threaded program's heaps: each of `threads` threads
//! takes a few blocks of every small size and `dense` bytes of one size,
//! writes them, and holds them; then the process's Rss and AnonHugePages.
const std = @import("std");
const alloc = @import("alloc");
const a = alloc.allocator;

const threads = 5;
var dense_bytes: usize = 2 << 20;

fn work() void {
    var len: usize = 16;
    while (len <= 32 << 10) : (len += @max(16, len / 16)) {
        for (0..2) |_| {
            const m = a.alloc(u8, len) catch unreachable;
            @memset(m, 1);
            std.mem.doNotOptimizeAway(m.ptr);
        }
    }
    var got: usize = 0;
    while (got < dense_bytes) : (got += 48) {
        const m = a.alloc(u8, 48) catch unreachable;
        @memset(m, 2);
        std.mem.doNotOptimizeAway(m.ptr);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var it_args = init.args.iterate();
    _ = it_args.next();
    if (it_args.next()) |s| dense_bytes = (try std.fmt.parseInt(usize, s, 10)) << 10;
    var ts: [threads - 1]std.Thread = undefined;
    for (&ts) |*t| t.* = try std.Thread.spawn(.{}, work, .{});
    work();
    for (ts) |t| t.join();
    var buf: [4096]u8 = undefined;
    const linux = std.os.linux;
    const fd: i32 = @intCast(linux.openat(linux.AT.FDCWD, "/proc/self/smaps_rollup", .{ .ACCMODE = .RDONLY }, 0));
    var n: usize = 0;
    while (true) {
        const r: isize = @bitCast(linux.read(fd, buf[n..].ptr, buf.len - n));
        if (r <= 0) break;
        n += @intCast(r);
    }
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "Rss:") or std.mem.startsWith(u8, line, "AnonHugePages:")) std.debug.print("{s}\n", .{line});
    }
}
