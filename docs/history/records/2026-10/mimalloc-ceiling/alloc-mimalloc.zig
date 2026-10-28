//! Measuring only (docs/history/records/2026-10/mimalloc-ceiling): Rig's
//! release allocator replaced by mimalloc 3.5.3, built from source into
//! the program by Zig's C compiler (`zig-wrap.sh`), with libc linked.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const Alignment = std.mem.Alignment;

pub const counts = builtin.is_test or (@hasDecl(root, "__rig_memory") and root.__rig_memory);
pub const Totals = struct { live: i64, peak: i64, allocs: i64 };
pub fn totals() Totals {
    @compileError("os.memory is not counted under the mimalloc shim");
}
pub fn threadExit() void {}

extern fn mi_malloc_aligned(size: usize, alignment: usize) ?*anyopaque;
extern fn mi_malloc(size: usize) ?*anyopaque;
extern fn mi_realloc_aligned(p: ?*anyopaque, newsize: usize, alignment: usize) ?*anyopaque;
extern fn mi_usable_size(p: ?*const anyopaque) usize;
extern fn mi_free(p: ?*anyopaque) void;

pub const allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
} };

fn alloc(_: *anyopaque, len: usize, a: Alignment, _: usize) ?[*]u8 {
    if (a.toByteUnits() <= 16) return @ptrCast(mi_malloc(len));
    return @ptrCast(mi_malloc_aligned(len, a.toByteUnits()));
}

fn resize(_: *anyopaque, m: []u8, _: Alignment, new_len: usize, _: usize) bool {
    if (new_len <= m.len) return true;
    return new_len <= mi_usable_size(m.ptr);
}

fn remap(_: *anyopaque, m: []u8, a: Alignment, new_len: usize, _: usize) ?[*]u8 {
    if (new_len <= mi_usable_size(m.ptr)) return m.ptr;
    return @ptrCast(mi_realloc_aligned(m.ptr, new_len, a.toByteUnits()));
}

fn free(_: *anyopaque, m: []u8, _: Alignment, _: usize) void {
    mi_free(m.ptr);
}
