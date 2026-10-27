//! mimalloc, built from bench/hash/upstream/mimalloc (fetch-deps pins
//! it) into the program, called as a Zig allocator.
const std = @import("std");
const Alignment = std.mem.Alignment;

extern fn mi_malloc_aligned(size: usize, alignment: usize) ?*anyopaque;
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
