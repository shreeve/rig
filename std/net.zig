//! `std.net`: TCP sockets, whose work is the runtime's (`rig/net.zig`):
//! these are the functions `std/net.rig` binds.

const rig = @import("../runtime.zig");
const net = rig.net;

pub const listen_on = net.listen_on;
pub const open_to = net.open_to;
pub const finish_connect = net.finish_connect;
pub const watch = net.watch;
pub const accept_on = net.accept_on;
pub const local_port = net.local_port;
pub const read_from = net.read_from;
pub const write_to = net.write_to;
pub const close = net.close;
pub const batch_on = net.batch_on;
pub const share = net.share;
pub const end_writing = net.end_writing;
pub const release = net.release;
