const ONES: u128 = 0x01010101010101010101010101010101;
export fn special128(p: [*]const u8) u128 {
    const w = @import("std").mem.readInt(u128, p[0..16], .little);
    const quote = w ^ (ONES *% 0x22);
    const slash = w ^ (ONES *% 0x5C);
    const zq = (quote -% ONES) & ~quote;
    const zs = (slash -% ONES) & ~slash;
    const ctl = (w -% ONES *% 0x20) & ~w;
    return (zq | zs | ctl | w) & (ONES *% 0x80);
}
const O64: u64 = 0x0101010101010101;
export fn special64w(p: [*]const u8) u64 {
    const w = @import("std").mem.readInt(u64, p[0..8], .little);
    const quote = w ^ (O64 *% 0x22);
    const slash = w ^ (O64 *% 0x5C);
    return (((quote -% O64) & ~quote) | ((slash -% O64) & ~slash) | ((w -% O64 *% 0x20) & ~w) | w) & (O64 *% 0x80);
}
