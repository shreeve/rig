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
        if (!rig.bytesEql(pair[0..eq], name)) continue;
        return fresh(if (eq < pair.len) pair[eq + 1 ..] else "");
    }
    return null;
}

/// The value of the header `name`, any case, in `head`, the request line
/// and headers, or null. `index` holds where each header lies in `head`,
/// four native `u16`s each (the offsets and lengths of its name and its
/// value, `rig/net.zig`'s `Index`); when it is empty, `head` is read.
pub fn header_of(head: []const u8, index: []const u8, name: []const u8) ?rig.String {
    if (index.len == 0) return scan(head, name);
    var at: usize = 0;
    while (at + 8 <= index.len) : (at += 8) {
        const e = index[at..][0..8];
        const name_at = std.mem.readInt(u16, e[0..2], .native);
        const name_len = std.mem.readInt(u16, e[2..4], .native);
        if (name_len != name.len) continue;
        const value_at = std.mem.readInt(u16, e[4..6], .native);
        const value_len = std.mem.readInt(u16, e[6..8], .native);
        // The index is the server's, made with `head`, and so inside it.
        if (@as(usize, name_at) + name_len > head.len or @as(usize, value_at) + value_len > head.len) return scan(head, name);
        if (!std.ascii.eqlIgnoreCase(head[name_at..][0..name_len], name)) continue;
        return fresh(head[value_at..][0..value_len]);
    }
    return null;
}

/// The value of the header `name` in `head`, read line by line.
fn scan(head: []const u8, name: []const u8) ?rig.String {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        return fresh(std.mem.trim(u8, line[colon + 1 ..], " \t"));
    }
    return null;
}
