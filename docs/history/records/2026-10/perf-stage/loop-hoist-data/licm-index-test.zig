const std = @import("std");
const S = struct { pad: u64, n: u64, slots: [*]u32 };
var counter: u32 = 1024;
noinline fn tick() void { std.mem.doNotOptimizeAway(&counter); }
fn idxPanic() noreturn { @branchHint(.cold); @panic("idx"); }
export fn find_plain(s: *S, start: u64, n: u64, x: u32) u64 { return body(s, start, n, x); }
export fn find_na(noalias s: *S, start: u64, n: u64, x: u32) u64 { return body(s, start, n, x); }
inline fn body(s: *S, start: u64, n: u64, x: u32) u64 {
    var turns: u32 = 1024;
    var k: u64 = 0;
    while (k < n) : ({ turns -%= 1; if (turns == 0) { @branchHint(.unlikely); turns = 1024; tick(); } k += 1; }) {
        const i = start + k;
        if (i >= (1 << 28)) idxPanic();
        if (s.slots[i] == x) return k;
    }
    return n;
}
pub fn main() void {}
