const Net = struct { timeout: i64 = 30, retries: i64 = 3, follow: bool = true, name: []const u8 = "anon" };

noinline fn flat(url: []const u8, timeout: i64, retries: i64, follow: bool, name: []const u8) i64 {
    return @as(i64, @intCast(url.len)) + timeout + retries + @intFromBool(follow) + @as(i64, @intCast(name.len));
}
noinline fn grouped(url: []const u8, net: Net) i64 {
    return @as(i64, @intCast(url.len)) + net.timeout + net.retries + @intFromBool(net.follow) + @as(i64, @intCast(net.name.len));
}
noinline fn viewed(url: []const u8, net: *const Net) i64 {
    return @as(i64, @intCast(url.len)) + net.timeout + net.retries + @intFromBool(net.follow) + @as(i64, @intCast(net.name.len));
}
export fn call_flat(p: [*]const u8, n: usize, t: i64) i64 {
    return flat(p[0..n], t, 3, true, "anon");
}
export fn call_grouped(p: [*]const u8, n: usize, t: i64) i64 {
    return grouped(p[0..n], .{ .timeout = t });
}
export fn call_viewed(p: [*]const u8, n: usize, t: i64) i64 {
    return viewed(p[0..n], &.{ .timeout = t });
}
