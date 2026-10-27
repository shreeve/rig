//! The table in bench/hash/hash.zig, as bench/hash/map.zig's `table`.
const ctx = @import("table_ctx.zig");
const tables = ctx.Tables(@import("hash.zig"));

pub const is_std = false;
pub const Auto = tables.Auto;
pub const String = tables.String;
pub const allocator = ctx.allocator;
