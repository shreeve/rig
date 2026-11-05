// vmabench PAGES STRIDE VMAS: map 64 GiB (MAP_NORESERVE, advised NOHUGEPAGE),
// write PAGES small pages, one every STRIDE KiB (4 = dense; 2048 = one per
// page-table page), split the mapping into about VMAS mappings by advising
// every other untouched 2 MiB stretch MADV_HUGEPAGE (as Rig's Tables split
// their region), then exit. Run under exitwatch, whose "reaped less at-exit"
// is the kernel's teardown of exactly this shape. Linux.
const std = @import("std");
const linux = std.os.linux;

pub fn main(init: std.process.Init.Minimal) !void {
    var it = init.args.iterate();
    _ = it.next();
    const pages = try std.fmt.parseInt(usize, it.next() orelse "10000", 10);
    const stride = (try std.fmt.parseInt(usize, it.next() orelse "4", 10)) << 10;
    const vmas = try std.fmt.parseInt(usize, it.next() orelse "1", 10);
    const size: usize = 64 << 30;
    const m = try std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
    const base = std.mem.alignForward(usize, @intFromPtr(m.ptr), 2 << 20);
    std.posix.madvise(@ptrFromInt(base), size - (2 << 20), linux.MADV.NOHUGEPAGE) catch {};
    // The pages, from the start.
    var i: usize = 0;
    while (i < pages) : (i += 1) {
        const p: *volatile u8 = @ptrFromInt(base + i * stride);
        p.* = 1;
    }
    // The splits, past what was written: each advised stretch makes two
    // mappings where one was.
    const after = std.mem.alignForward(usize, base + pages * stride, 2 << 20) + (2 << 20);
    var k: usize = 0;
    while (k + 1 < vmas / 2 + 1 and k < 8000) : (k += 1) {
        const at = after + k * (4 << 20);
        std.posix.madvise(@ptrFromInt(at), 2 << 20, linux.MADV.HUGEPAGE) catch {};
    }
    linux.exit_group(0);
}
