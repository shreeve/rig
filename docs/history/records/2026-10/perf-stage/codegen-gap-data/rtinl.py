p = "rig/runtime.zig"; s = open(p).read()
old = '''pub fn rt(value: anytype) @TypeOf(value) {
    return value;
}'''
new = '''pub inline fn rt(value: anytype) @TypeOf(value) {
    // CEILING rt: an object, optional or array passes through with no
    // call, so no temporary is written in parts and read whole; a scalar
    // still passes through a call, as before.
    switch (@typeInfo(@TypeOf(value))) {
        .@"struct", .@"union", .optional, .array => return value,
        else => return rtCall(value),
    }
}

fn rtCall(value: anytype) @TypeOf(value) {
    return value;
}'''
assert s.count(old) == 1
open(p, "w").write(s.replace(old, new))
