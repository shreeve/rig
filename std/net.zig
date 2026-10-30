//! `std.net`: TCP sockets, whose work is the runtime's (`rig/net.zig`):
//! these are the functions `std/net.rig` binds.

const rig = @import("../runtime.zig");
const net = rig.net;

pub fn listen_on(addr: []const u8) net.Error!i64 {
    return net.listen_on(addr);
}

pub fn open_to(addr: []const u8) net.Error!i64 {
    return net.open_to(addr);
}

pub fn finish_connect(fd: i64, reg: i64) net.Error!void {
    return net.finish_connect(fd, reg);
}

pub fn watch(fd: i64) i64 {
    return net.watch(fd);
}

pub fn accept_on(fd: i64, reg: i64) net.Error!i64 {
    return net.accept_on(fd, reg);
}

pub fn local_port(fd: i64) i64 {
    return net.local_port(fd);
}

pub fn read_from(fd: i64, reg: i64, into: *rig.String, max: i64) net.Error!i64 {
    return net.read_from(fd, reg, into, max);
}

pub fn write_to(fd: i64, reg: i64, bytes: []const u8) net.Error!void {
    return net.write_to(fd, reg, bytes);
}

pub fn close(fd: i64, reg: i64) void {
    net.close(fd, reg);
}

pub fn batch_on(fd: i64, on: bool) void {
    net.batch_on(fd, on);
}

pub fn share() i64 {
    return net.share();
}

pub fn end_writing(fd: i64) void {
    net.end_writing(fd);
}

pub fn release(fd: i64, reg: i64, pair: i64) void {
    net.release(fd, reg, pair);
}
