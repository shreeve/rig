//! `std.sort`: the one fact about a type its sorts need that Rig cannot
//! ask in Rig, decided where `rig.order` decides how the type orders.

const rig = @import("../runtime.zig");

/// Whether two `T`s that `<` finds equal are the same value
/// (`rig.orderIsIdentity`), known when the program compiles.
pub inline fn equal_is_same(comptime T: type) bool {
    return comptime rig.orderIsIdentity(T);
}
