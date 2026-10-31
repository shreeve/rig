//! `std.http`: reading a request's query and headers. The server is the
//! runtime's (`rig/net.zig`, `serve`).

const std = @import("std");
const rig = @import("../runtime.zig");

fn fresh(bytes: []const u8) rig.String {
    return .ofBytes(bytes);
}

/// The value of `name` in `query` (`a=1&b=2`), as written, or null.
pub fn arg_of(query: []const u8, name: []const u8) ?rig.String {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse pair.len;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        return fresh(if (eq < pair.len) pair[eq + 1 ..] else "");
    }
    return null;
}

/// The value of the header `name`, any case, in `head`, the request line
/// and headers, or null.
pub fn header_of(head: []const u8, name: []const u8) ?rig.String {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        return fresh(std.mem.trim(u8, line[colon + 1 ..], " \t"));
    }
    return null;
}
