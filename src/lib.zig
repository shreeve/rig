//! The compiler as a library, for test tools (`bin/rig-oracle`).
//! `bin/rig` never imports this file.

pub const modules = @import("modules.zig");
pub const sema = @import("sema.zig");
pub const parser = @import("parser.zig");
pub const rig = @import("rig.zig");
pub const diag = @import("diag.zig");
