"""Runtime: a vector read of 16 bytes or more loads through an `align(1)`
vector pointer, in place of copying a `[n]u8` and bit-casting it, which
LLVM assembles a byte at a time on x86 for 64 bytes (stores to the stack,
then a reload that waits on them). Combine: src:wsbits3+vread."""


def patch(s):
    return s


def patch_runtime(r):
    old = """    const raw: [n]u8 = bytes[i..][0..n].*;
    return lanesInOrder(@as(V, @bitCast(raw)), endian);"""
    assert r.count(old) == 1
    new = """    if (comptime n >= 16 and @sizeOf(V) == n) {
        const p: *align(1) const V = @ptrCast(bytes[i..][0..n]);
        return lanesInOrder(p.*, endian);
    }
    const raw: [n]u8 = bytes[i..][0..n].*;
    return lanesInOrder(@as(V, @bitCast(raw)), endian);"""
    return r.replace(old, new)
