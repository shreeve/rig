import sys, re; sys.path.insert(0, sys.argv[1]); from sub import sub
# Table: a bulk push and a range read, each with one test.
sub('rig/table.zig', '''        /// A slot's offset: below `n` by its type''', '''        /// CEILING se6: `xs` pushed in order, with one test that they fit
        /// and one copy; a table whose slots drop, or that commits as it is
        /// written, pushes each.
        pub fn appendSlice(self: *Self, xs: []const T) void {
            if (comptime rt.needsDrop(T) or how == .committed) {
                for (xs) |x| _ = self.push(x);
                return;
            }
            if (xs.len > n - self.len) fullPanic(n);
            @memcpy(self.slots[@intCast(self.len)..][0..xs.len], xs);
            self.len += xs.len;
        }

        /// CEILING se6: slots `lo..lo + count`, read in place, with one
        /// test that the last is below `n`; null for a committed table,
        /// whose caller reads each.
        pub inline fn constRange(self: *const Self, lo: u64, count: u64) ?[]const T {
            if (comptime how == .committed) return null;
            if (lo + count > n) rt.indexPanicPub();
            return self.slots[@intCast(lo)..][0..@intCast(count)];
        }

        /// A slot's offset: below `n` by its type''')
sub('rig/runtime.zig', '''fn indexPanic() noreturn {''', '''pub fn indexPanicPub() noreturn {
    indexPanic();
}

fn indexPanic() noreturn {''')
s = open('checker.zig').read()
pat_new = re.compile(r'''(        const start: u32 = @as\(u32, @intCast\(@as\(u64, @intCast\(@as\(i64, rig\.lenOf\(self\.store\.(\w+)\)\)\)\)\)\);\n)        \{\n            var __rig_turns_\d+: u32 = rig\.tick_turns;\n            for \(items\) \|x\| \{\n                rig\.turn\(&__rig_turns_\d+\);\n                _ = self\.store\.\2\.push\(x\);\n            \}\n        \}\n''')
s, k1 = pat_new.subn(lambda m: m.group(1) + f'        // CEILING se6: one test and one copy for the items.\n        self.store.{m.group(2)}.appendSlice(items);\n', s)
pat_items = re.compile(r'''        var out: (rig\.List\([^\n]*\)) = rig\.List\([^\n]*\)\.empty;\n        var __rig_alive_out = true;\n        defer if \(__rig_alive_out\) \{ __rig_alive_out = false; rig\.drop\(&out\); \};\n        \{\n            var __rig_turns_\d+: u32 = rig\.tick_turns;\n            var __rig_i_\d+: i64 = 0;\n            const __rig_end_\d+: i64 = @as\(i64, @intCast\(@as\(u32, list\.count\)\)\);\n            while [^\n]*\n                const k = __rig_i_\d+;\n                out\.push\(self\.store\.(\w+)\.atInt\(@as\(i64, @intCast\(@as\(u32, list\.start\)\)\) \+ k\)\);\n            \}\n        \}\n        return rig\.take\(&__rig_alive_out, out\);\n''')
def rep(m):
    L, tab = m.group(1), m.group(2)
    return (f'        // CEILING se6: the range tested once, copied into a List of\n'
            f'        // exactly its length (one allocation, one copy).\n'
            f'        if (list.count == 0) return {L}.empty;\n'
            f'        if (self.store.{tab}.constRange(list.start, list.count)) |xs| return {L}.fromSlice(xs);\n'
            + m.group(0))
s, k2 = pat_items.subn(rep, s)
print('new lists', k1, 'items', k2)
assert k1 == 8 and k2 == 8
open('checker.zig', 'w').write(s)
