const Net = struct { timeout: i64 = 30, retries: i64 = 3, follow: bool = true, name: []const u8 = "anon" };
var sink: i64 = 0;
noinline fn flat(url: []const u8, timeout: i64, retries: i64, follow: bool, name: []const u8) void {
    sink +%= @as(i64, @intCast(url.len)) +% @as(i64, @intCast(@intFromPtr(url.ptr))) +% timeout +% retries +% @intFromBool(follow) +% @as(i64, @intCast(name.len)) +% @as(i64, @intCast(@intFromPtr(name.ptr)));
}
noinline fn grouped(url: []const u8, net: Net) void {
    sink +%= @as(i64, @intCast(url.len)) +% @as(i64, @intCast(@intFromPtr(url.ptr))) +% net.timeout +% net.retries +% @intFromBool(net.follow) +% @as(i64, @intCast(net.name.len)) +% @as(i64, @intCast(@intFromPtr(net.name.ptr)));
}
export fn call_flat(p: [*]const u8, n: usize, t: i64, r: i64, f: bool, q: [*]const u8, m: usize) void {
    flat(p[0..n], t, r, f, q[0..m]);
}
export fn call_grouped(p: [*]const u8, n: usize, t: i64, r: i64, f: bool, q: [*]const u8, m: usize) void {
    grouped(p[0..n], .{ .timeout = t, .retries = r, .follow = f, .name = q[0..m] });
}
export fn call_grouped_stored(p: [*]const u8, n: usize, net: *const Net) void {
    grouped(p[0..n], net.*);
}
export fn call_flat_stored(p: [*]const u8, n: usize, net: *const Net) void {
    flat(p[0..n], net.timeout, net.retries, net.follow, net.name);
}
