const std = @import("std");
pub const S = extern struct { ptr: [*]const u64, len: usize };
var counter: u32 = 0;
fn cold() callconv(.c) void { counter +%= 1; }
inline fn tickMem(n: *u32) void {
    n.* -%= 1;
    if (n.* == 0) { @branchHint(.unlikely); n.* = 1024; asm volatile ("bl %[f]" : : [f] "X" (&cold) : .{ .memory = true, .nzcv = true, .x30 = true }); }
}
inline fn tickNoMem(n: *u32) void {
    n.* -%= 1;
    if (n.* == 0) { @branchHint(.unlikely); n.* = 1024; asm volatile ("bl %[f]" : : [f] "X" (&cold) : .{ .nzcv = true, .x30 = true }); }
}
export fn sumMem(s: *const S) u64 {
    var n: u32 = 1024; var t: u64 = 0; var i: usize = 0;
    while (i < s.len) : ({ tickMem(&n); i += 1; }) t +%= s.ptr[i];
    return t;
}
export fn sumNoMem(s: *const S) u64 {
    var n: u32 = 1024; var t: u64 = 0; var i: usize = 0;
    while (i < s.len) : ({ tickNoMem(&n); i += 1; }) t +%= s.ptr[i];
    return t;
}
export fn sumNone(s: *const S) u64 {
    var t: u64 = 0; var i: usize = 0;
    while (i < s.len) : (i += 1) t +%= s.ptr[i];
    return t;
}
fn cold2() callconv(.c) u32 { counter +%= 1; return 1024; }
inline fn tickPure(n: *u32) void {
    n.* -%= 1;
    if (n.* == 0) { @branchHint(.unlikely); n.* = asm ("bl %[f]" : [ret] "={w0}" (-> u32) : [f] "X" (&cold2) : .{ .nzcv = true, .x30 = true }); }
}
export fn sumPure(s: *const S) u64 {
    var n: u32 = 1024; var t: u64 = 0; var i: usize = 0;
    while (i < s.len) : ({ tickPure(&n); i += 1; }) t +%= s.ptr[i];
    return t;
}
