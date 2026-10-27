//! libc's `malloc`, the default: the C++ and Rust contestants allocate
//! from it too, so a row times the table, not the allocator.
const std = @import("std");

pub const allocator = std.heap.c_allocator;
