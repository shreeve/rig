//! `std.target`: the target's facts, which Zig knows when it compiles
//! the program for that target.

const builtin = @import("builtin");

pub const arch = builtin.cpu.arch;
