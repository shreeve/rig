//! `std.http`: reading a request's query and headers. The server is the
//! runtime's (`rig/net.zig`, `serve`).

const std = @import("std");
const rig = @import("../runtime.zig");

fn fresh(bytes: []const u8) rig.String {
    return .ofBytes(bytes);
}

/// The value of `name` in `query` (`a=1&b=2`), as written, or null.
/// A pair's name is the text before its first `=`. Each pair's start is
/// compared with `name` and its end found, with no split.
pub fn arg_of(query: []const u8, name: []const u8) ?rig.String {
    var at: usize = 0;
    while (true) {
        const end = std.mem.findScalarPos(u8, query, at, '&') orelse query.len;
        const pair = query[at..end];
        if (pair.len >= name.len and rig.bytesEql(pair[0..name.len], name)) {
            if (pair.len == name.len) return if (named(name)) fresh("") else null;
            if (pair[name.len] == '=') return if (named(name)) fresh(pair[name.len + 1 ..]) else null;
        }
        if (end == query.len) return null;
        at = end + 1;
    }
}

/// Whether `name` can be a pair's name, which ends at the pair's first
/// `=`. (A name holding `&` matches no pair's start.)
fn named(name: []const u8) bool {
    return std.mem.findScalar(u8, name, '=') == null;
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
