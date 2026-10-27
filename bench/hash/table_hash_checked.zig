//! bench/hash/hash.zig with `.checked = true`: the bounds tests safe Rig
//! keeps put back, as map.zig's `table`, so every run shows what they cost.
const ctx = @import("table_ctx.zig");
const impl = @import("hash.zig");
const tables = ctx.Tables(struct {
    pub fn HashMap(comptime K: type, comptime V: type, comptime Context: type) type {
        return impl.HashMapWith(K, V, Context, .{ .checked = true });
    }
});

pub const is_std = false;
pub const Auto = tables.Auto;
pub const String = tables.String;
pub const allocator = ctx.allocator;
