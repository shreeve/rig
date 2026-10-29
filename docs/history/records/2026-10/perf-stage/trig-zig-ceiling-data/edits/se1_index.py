import sys; sys.path.insert(0, sys.argv[1]); from sub import sub
sub('rig/runtime.zig', '''pub fn index(i: anytype, count: usize) usize {
    const idx = std.math.cast(usize, i) orelse indexPanic();''', '''pub fn index(i: anytype, count: usize) usize {
    // CEILING se1: a signed index is one unsigned compare. Every count
    // here is a length (a List's at most `max_len`, a slice's below 2^63),
    // so a negative `i`, read as at least 2^63, fails it too.
    const info = @typeInfo(@TypeOf(i));
    if (comptime info == .int and info.int.signedness == .signed and info.int.bits <= 64) {
        const u: u64 = @bitCast(@as(i64, i));
        if (u >= count) indexPanic();
        return @truncate(u);
    }
    const idx = std.math.cast(usize, i) orelse indexPanic();''')
