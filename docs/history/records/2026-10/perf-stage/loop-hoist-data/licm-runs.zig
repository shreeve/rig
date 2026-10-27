const std = @import("std");
const S = struct { pad: u64, n: u64, slots: [*]u32 };
var counter: u32 = 1024;
noinline fn tick() void { std.mem.doNotOptimizeAway(&counter); }
fn idxPanic() noreturn { @branchHint(.cold); @panic("idx"); }
export fn find_chunk(s: *S, start: u64, n: u64, x: u32) u64 {
    var turns: u32 = 1024;
    var k: u64 = 0;
    const end = n;
    while (k < end) {
        const stop = k + @min(end - k, turns);
        turns -= @intCast(stop - k);
        while (k < stop) : (k += 1) {
            const i = start + k;
            if (s.slots[i] == x) return k;
        }
        if (turns == 0) { turns = 1024; tick(); }
    }
    return n;
}
export fn find_chunk_b(s: *S, start: u64, n: u64, x: u32) u64 {
    var turns: u32 = 1024;
    var k: u64 = 0;
    const end = n;
    while (k < end) {
        const stop = k + @min(end - k, turns);
        turns -= @intCast(stop - k);
        while (k < stop) : (k += 1) {
            const i = start + k;
            if (i >= (1 << 28)) idxPanic();
            if (s.slots[i] == x) return k;
        }
        if (turns == 0) { turns = 1024; tick(); }
    }
    return n;
}
pub fn main() void {}
