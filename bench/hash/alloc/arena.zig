//! An `ArenaAllocator` over `page_allocator`: a free gives back only the
//! newest block, and everything goes back to the system after each row
//! (`reset`, which map.zig calls), as a program frees an arena after each
//! request.
const std = @import("std");

var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

pub const allocator = arena.allocator();

pub fn reset() void {
    _ = arena.reset(.free_all);
}
