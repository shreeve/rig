//! Measuring only (docs/history/records/2026-10/mimalloc-ceiling): Rig's
//! release allocator replaced by glibc's malloc (`std.heap.c_allocator`),
//! with libc linked (`zig-wrap.sh`).
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const Alignment = std.mem.Alignment;

pub const counts = builtin.is_test or (@hasDecl(root, "__rig_memory") and root.__rig_memory);
pub const Totals = struct { live: i64, peak: i64, allocs: i64 };
pub fn totals() Totals {
    @compileError("os.memory is not counted under the malloc shim");
}
pub fn threadExit() void {}

pub const allocator: std.mem.Allocator = std.heap.c_allocator;
