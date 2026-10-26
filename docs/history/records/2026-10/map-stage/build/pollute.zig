//! pollute: read a 256 MiB buffer a cache line at a time, forever, so a
//! program beside it finds the shared cache cold.
const std = @import("std");
pub fn main() void {
    const n = 256 << 20;
    const buf = std.heap.page_allocator.alloc(u8, n) catch return;
    @memset(buf, 1);
    var sum: u64 = 0;
    var i: usize = 0;
    while (true) {
        sum +%= buf[i];
        i = (i + 64 * 7) % n;
        if (sum == 0xdeadbeef) std.debug.print("{d}\n", .{sum});
    }
}
