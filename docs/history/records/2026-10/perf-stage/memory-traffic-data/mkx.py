#!/usr/bin/env python3
# mkx.py PKG: the ceiling experiments, hand-written into a copy of Trig's
# emitted package (packs/rel/out), each switched on at run time by a bit of
# $RIG_X so that one binary times every arm:
#   1  a Map index of 2 MiB or more in its own mapping, aligned to 2 MiB,
#      its whole 2 MiB stretches advised MADV_HUGEPAGE (the tail keeps
#      small pages: no memory beyond what the index writes anyway)
#   2  a reserved Table faults in, in one call, the RIG_X_AHEAD bytes
#      (default 64 KiB) past the slot a push reaches
#   4  get_relater pops the pool's last Relater in place, put_relater
#      pushes its argument with no copy through rig.rt and rig.take, and
#      their two callers take the result with no rig.rt copy
import sys, re
pkg = sys.argv[1]
def edit(path, pairs):
    s = open(path).read()
    for a, b in pairs:
        assert s.count(a) >= 1, (path, a[:80])
        s = s.replace(a, b)
    open(path, 'w').write(s)

edit(pkg + '/rig/runtime.zig', [
('''pub fn start(init: std.process.Init.Minimal) void {
    process = init;''', '''/// The ceiling experiments' switches ($RIG_X, bits), and the table
/// prefault distance ($RIG_X_AHEAD).
pub var xflags: u32 = 0;
pub var x_ahead: usize = 64 << 10;

pub fn start(init: std.process.Init.Minimal) void {
    process = init;
    if (init.environ.getPosix("RIG_X")) |v| xflags = std.fmt.parseInt(u32, v, 10) catch 0;
    if (init.environ.getPosix("RIG_X_AHEAD")) |v| x_ahead = std.fmt.parseInt(usize, v, 10) catch x_ahead;'''),
])

edit(pkg + '/rig/table.zig', [
('''        /// The leak checker's record of the mapping (`token`).''', '''        /// Experiment 2: the bytes faulted in so far.
        ahead: usize = 0,
        /// The leak checker's record of the mapping (`token`).'''),
('''            if (self.len == n) fullPanic(n);
            const s: Index = @intCast(self.len);''', '''            if (self.len == n) fullPanic(n);
            if (comptime how == .reserved) if (rt.xflags & 2 != 0) {
                const x_end = (@as(usize, @intCast(self.len)) + 1) * @sizeOf(T);
                if (x_end > self.ahead) self.faultAhead(x_end);
            };
            const s: Index = @intCast(self.len);'''),
('''        /// A slot's offset: below `n` by its type''', '''        noinline fn faultAhead(self: *Self, x_end: usize) void {
            @branchHint(.cold);
            const x_start = std.mem.alignBackward(usize, @max(self.ahead, x_end - 1), page);
            const x_stop = @min(bytes, std.mem.alignForward(usize, x_end, page) + rt.x_ahead);
            if (x_stop > x_start) {
                const x_addr: [*]align(page) u8 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(self.slots)) + x_start));
                std.posix.madvise(x_addr, x_stop - x_start, 23) catch {};
            }
            self.ahead = x_stop;
        }

        /// A slot's offset: below `n` by its type'''),
])

edit(pkg + '/rig/ordered.zig', [
('''        fn freeIndex(self: *Self) void {
            if (self.groups != 0) rt.freeSlice(u64, self.indexBlock());''', '''        fn freeIndex(self: *Self) void {
            if (self.groups != 0) {
                const hx_blk = self.indexBlock();
                if (huge_index.forget(@intFromPtr(hx_blk.ptr))) |hx_n| {
                    std.posix.munmap(@as([*]align(huge_index.huge) u8, @ptrFromInt(@intFromPtr(hx_blk.ptr)))[0..hx_n]);
                } else rt.freeSlice(u64, hx_blk);
            }'''),
('''            self.freeIndex();
            const b = rt.allocSlice(u64, indexWords(groups));''', '''            self.freeIndex();
            const b = if (rt.xflags & 1 != 0 and indexWords(groups) * 8 >= huge_index.huge) huge_index.take(indexWords(groups)) else rt.allocSlice(u64, indexWords(groups));'''),
('''/// `Map[K, V]`'s table.''', '''/// Experiment 1: a large index in its own 2 MiB-aligned mapping, advised
/// huge over its whole 2 MiB stretches. A few dozen at most.
const huge_index = struct {
    const huge: usize = 2 << 20;
    var hx_at: [64]usize = @splat(0);
    var hx_len: [64]usize = @splat(0);
    fn take(hx_words: usize) []u64 {
        const hx_bytes = hx_words * 8;
        const hx_map = std.mem.alignForward(usize, hx_bytes, std.heap.pageSize());
        const hx_raw = std.posix.mmap(null, hx_map + huge, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch @panic("oom");
        const hx_lo = @intFromPtr(hx_raw.ptr);
        const hx_start = std.mem.alignForward(usize, hx_lo, huge);
        if (hx_start > hx_lo) std.posix.munmap(hx_raw[0 .. hx_start - hx_lo]);
        const hx_end = hx_lo + hx_map + huge;
        if (hx_end > hx_start + hx_map) std.posix.munmap(@as([*]align(4096) u8, @ptrFromInt(hx_start + hx_map))[0 .. hx_end - hx_start - hx_map]);
        const hx_whole = hx_bytes / huge * huge;
        std.posix.madvise(@ptrFromInt(hx_start), hx_whole, std.posix.MADV.HUGEPAGE) catch {};
        for (&hx_at, &hx_len) |*hx_a, *hx_l| if (hx_a.* == 0) {
            hx_a.* = hx_start;
            hx_l.* = hx_map;
            break;
        };
        return @as([*]u64, @ptrFromInt(hx_start))[0..hx_words];
    }
    fn forget(hx_p: usize) ?usize {
        for (&hx_at, &hx_len) |*hx_a, *hx_l| if (hx_a.* == hx_p) {
            hx_a.* = 0;
            return hx_l.*;
        };
        return null;
    }
};

/// `Map[K, V]`'s table.'''),
])

c = pkg + '/checker.zig'
edit(c, [
('''    pub inline fn get_relater(__rig_in_self: *Checker) Relater {
        const self = rig.rt(__rig_in_self);
        return (rig.some(self.free_relaters.pop()) orelse Relater{});''', '''    pub inline fn get_relater(__rig_in_self: *Checker) Relater {
        const self = rig.rt(__rig_in_self);
        if (rig.xflags & 4 != 0) {
            const x_l = &self.free_relaters;
            if (x_l.len == 0) return Relater{};
            x_l.len -= 1;
            return x_l.buf.ptr[x_l.len];
        }
        return (rig.some(self.free_relaters.pop()) orelse Relater{});'''),
('''    pub inline fn put_relater(__rig_in_self: *Checker, __rig_arg_10404: Relater) void {
        const self = rig.rt(__rig_in_self);''', '''    pub inline fn put_relater(__rig_in_self: *Checker, __rig_arg_10404: Relater) void {
        const self = rig.rt(__rig_in_self);
        if (rig.xflags & 4 != 0) {
            const x_l = &self.free_relaters;
            if (x_l.len == x_l.buf.len) x_l.reserve(1);
            const x_r = &x_l.buf.ptr[x_l.len];
            x_r.* = __rig_arg_10404;
            x_l.len += 1;
            rig.rt(x_r.maybe_keys_set.clear());
            x_r.maybe_keys.clear();
            x_r.source_stack.clear();
            x_r.target_stack.clear();
            x_r.chains.clear();
            x_r.related_info.clear();
            x_r.relation = .Identity;
            x_r.error_node = NodeRef{};
            x_r.error_chain = 0;
            x_r.maybe_count = 0;
            x_r.source_depth = 0;
            x_r.target_depth = 0;
            x_r.expanding_flags = 0;
            x_r.overflow = false;
            x_r.relation_count = 0;
            return;
        }'''),
])
s = open(c).read()
n = s.count('var r = rig.rt(self.get_relater());')
assert n == 2, n
s = s.replace('var r = rig.rt(self.get_relater());', 'var r = if (rig.xflags & 4 != 0) self.get_relater() else rig.rt(self.get_relater());')
open(c, 'w').write(s)
print('ok')
