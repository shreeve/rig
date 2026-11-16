//! `std.sort`: what its sorts need that Rig cannot say in Rig. The one
//! fact about a type, decided where `rig.order` decides how the type
//! orders; and the stable merge's room, memory for elements none of which
//! it owns, with the moves between it and the slice being sorted.
//!
//! A move here copies an element's bits and drops nothing: the slot it
//! is written to held no element (a slot of the room, or one a move
//! emptied), and the slot it is read from holds none after, until a move
//! fills it again. sort.rig's `merge_by` keeps that, so every element is
//! in the slice exactly once when it returns. A panic in the comparator
//! midway leaves a slot's element in two places, but a panic runs no
//! drop (SPEC §17), so neither copy is dropped.

const std = @import("std");
const rig = @import("../runtime.zig");

/// Whether two `T`s that `<` finds equal are the same value
/// (`rig.orderIsIdentity`), known when the program compiles.
pub inline fn equal_is_same(comptime T: type) bool {
    return comptime rig.orderIsIdentity(T);
}

/// A room's memory is aligned for any element.
const room_align: std.mem.Alignment = .@"64";

/// The address of memory for `n` `T`s, none of them written; 64 when
/// they take no bytes.
pub fn room_alloc(comptime T: type, n: i64) i64 {
    comptime std.debug.assert(@alignOf(T) <= room_align.toByteUnits());
    const bytes = room_bytes(T, n);
    if (bytes == 0) return @intCast(room_align.toByteUnits());
    const p = rig.defaultAllocator().rawAlloc(@intCast(bytes), room_align, @returnAddress()) orelse rig.oom();
    return @intCast(@intFromPtr(p));
}

/// The bytes `n` `T`s take.
pub fn room_bytes(comptime T: type, n: i64) i64 {
    return @intCast(std.math.mul(usize, @sizeOf(T), @intCast(n)) catch rig.oom());
}

/// Free the `bytes` bytes at `addr` that `room_alloc` gave, dropping no
/// element.
pub fn room_free(addr: i64, bytes: i64) void {
    if (bytes == 0) return;
    const p: [*]u8 = @ptrFromInt(@as(usize, @intCast(addr)));
    rig.defaultAllocator().rawFree(p[0..@intCast(bytes)], room_align, @returnAddress());
}

/// The room `r` holds (`sort.Room`), as a slice of its `cap` slots.
pub inline fn room_slots(comptime T: type, r: anytype) []T {
    const p: [*]T = @ptrFromInt(@as(usize, @intCast(r.addr)));
    return p[0..@intCast(r.cap)];
}

/// Move `from[i..i + n]` to `to[at..at + n]`, two slices that do not
/// overlap. Each index is std's own, so Zig's safety checks test them.
pub inline fn move_to(comptime T: type, to: []T, at: i64, from: []const T, i: i64, n: i64) void {
    const len: usize = @intCast(n);
    @memcpy(to[@intCast(at)..][0..len], from[@intCast(i)..][0..len]);
}

/// Move `xs[j]` to `xs[at]` when `take`, else `from[i]`: a merge's
/// step, which loads from the one address it selects, so random input
/// costs it no mispredicted branch.
pub inline fn pick_one(comptime T: type, xs: []T, at: i64, j: i64, from: []const T, i: i64, take: bool) void {
    const a: *const T = &xs[@intCast(j)];
    const b: *const T = &from[@intCast(i)];
    xs[@intCast(at)] = (if (take) a else b).*;
}

/// Move `from[i]` to `to[at]`.
pub inline fn move_one(comptime T: type, to: []T, at: i64, from: []const T, i: i64) void {
    to[@intCast(at)] = from[@intCast(i)];
}

/// Move `xs[i]` to `xs[at]`.
pub inline fn shift_one(comptime T: type, xs: []T, at: i64, i: i64) void {
    xs[@intCast(at)] = xs[@intCast(i)];
}
