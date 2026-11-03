# patch-zig.py OUT: add the Table registry (table.zig) and the per-owner heap
# dump (runtime.zig) that std.memwalk reads, to Rig's emitted package OUT.
import sys
out = sys.argv[1]
p = f"{out}/rig/table.zig"; s = open(p).read()
old = "                .reserved => {\n                    const p = reserve(bytes);\n"
assert s.count(old) == 1, "table reserve"
s = s.replace(old, old + "                    memwalkAdd(@typeName(T), @sizeOf(T), n, @intFromPtr(p), bytes);\n")
s += '''
pub const MemwalkTable = struct { name: []const u8, size: usize, n: u64, p: usize, bytes: usize };
pub var memwalk_tables: [1024]MemwalkTable = undefined;
pub var memwalk_count: std.atomic.Value(usize) = .init(0);
fn memwalkAdd(name: []const u8, size: usize, n: u64, p: usize, bytes: usize) void {
    const i = memwalk_count.fetchAdd(1, .monotonic);
    if (i < memwalk_tables.len) memwalk_tables[i] = .{ .name = name, .size = size, .n = n, .p = p, .bytes = bytes } else _ = memwalk_count.fetchSub(1, .monotonic);
}
'''
open(p, "w").write(s)
r = f"{out}/rig/runtime.zig"; t = open(r).read()
t += '''
pub fn memwalkOwners(fd: i32) void {
    if (!heap_profile) return;
    HeapProfile.lock();
    defer HeapProfile.unlock();
    for (heap_profiler.owners.items) |o| {
        if (o.live == 0) continue;
        var lb: [600]u8 = undefined;
        const line = std.fmt.bufPrint(&lb, "{d} {d} {d} {s}\\n", .{ o.live, o.blocks, o.made, o.name }) catch continue;
        _ = std.os.linux.write(fd, line.ptr, line.len);
    }
}
'''
open(r, "w").write(t)
print("patched", out)
