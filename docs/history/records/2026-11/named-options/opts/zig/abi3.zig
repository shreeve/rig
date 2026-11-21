const Net = struct { timeout: i64 = 30, retries: i64 = 3, follow: bool = true, name: []const u8 = "anon" };
var sink: i64 = 0;
noinline fn flat(timeout: i64, retries: i64, follow: bool, name: []const u8) void {
    sink +%= timeout +% retries +% @intFromBool(follow) +% @as(i64, @intCast(name.len));
}
noinline fn viewed(net: *const Net) void {
    sink +%= net.timeout +% net.retries +% @intFromBool(net.follow) +% @as(i64, @intCast(net.name.len));
}
const F = *const fn (i64, i64, bool, []const u8) void;
export fn call_viewed_stored(net: *const Net) void { viewed(net); }
// call through a value: defaults filled from the group type, flat args, no thunk
export fn call_value(t: i64, pick: bool) void {
    const f: F = if (pick) &flat else &flat;
    f(t, (Net{}).retries, (Net{}).follow, (Net{}).name);
}
