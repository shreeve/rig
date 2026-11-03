# Patch an emitted package's rig/runtime.zig: String's push, reserve, pushInt and pushKeep
# grow by value (growBy), so a String local's fields stay in registers in a push loop.
import sys
p = sys.argv[1] + '/rig/runtime.zig'; s = open(p).read()
reps = [
('''    pub fn push(self: *String, b: u8) void {
        const l = &self.list;
        if (l.items.len == l.capacity) self.grow(1);
        invariant(l.items.len < l.capacity);
        l.items.ptr[l.items.len] = b;
        l.items.len +%= 1;
    }''','''    pub fn push(self: *String, b: u8) void {
        var l = self.list;
        if (l.items.len == l.capacity) l = growBy(l, 1);
        l.items.ptr[l.items.len] = b;
        l.items.len +%= 1;
        self.list = l;
    }

    noinline fn growBy(l0: std.ArrayList(u8), extra: usize) std.ArrayList(u8) {
        var s: String = .{ .list = l0 };
        s.grow(extra);
        return s.list;
    }'''),
('''        const l = &self.list;
        if (l.capacity -% l.items.len < extra) self.grow(extra);
        invariant(l.capacity -% l.items.len >= extra);
    }''','''        if (self.list.capacity -% self.list.items.len < extra) self.list = growBy(self.list, extra);
    }'''),
('''        const l = &self.list;
        const used = l.items.len;
        if (l.capacity -% used < n) self.grow(n);
        invariant(l.capacity -% used >= n);
        // One store of all `n` bytes''','''        var lv = self.list;
        defer self.list = lv;
        const l = &lv;
        const used = l.items.len;
        if (l.capacity -% used < n) lv = growBy(lv, n);
        // One store of all `n` bytes'''),
]
for a, b in reps:
    assert a in s, a[:60]
    s = s.replace(a, b)
open(p, 'w').write(s)
