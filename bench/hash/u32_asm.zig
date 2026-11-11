//! The lookups of u32.zig's tables as exported functions, to read their code.
const today = @import("ordered.zig");
const nu = @import("ordered_u32.zig");
const Ctx = nu.U32Ctx;
const T = today.HashMap(u32, u32, Ctx);
const N8 = nu.Ordered(u32, u32, Ctx, .{ .width = 8 });
const N16 = nu.Ordered(u32, u32, Ctx, .{ .width = 16 });
const N8c = nu.Ordered(u32, u32, Ctx, .{ .width = 8, .layout = .soa });
export fn today_get(m: *const T, k: u32) u32 {
    return m.get(k) orelse 7;
}
export fn new8_get(m: *const N8, k: u32) u32 {
    return m.get(k) orelse 7;
}
export fn new16_get(m: *const N16, k: u32) u32 {
    return m.get(k) orelse 7;
}
export fn new8soa_get(m: *const N8c, k: u32) u32 {
    return m.get(k) orelse 7;
}
