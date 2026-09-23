//! The runtime shipped with every emitted program. The source lives in
//! `runtime/_runtime.zig`, a real Zig file that is compiled and unit
//! tested with the compiler; the driver writes it byte for byte next to
//! the emitted modules, which import it as `rig`.

pub const filename = "_runtime.zig";

pub const source = @embedFile("runtime/_runtime.zig");

test {
    _ = @import("runtime/_runtime.zig");
}
