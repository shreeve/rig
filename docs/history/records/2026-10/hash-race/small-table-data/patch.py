import sys
d, mode = sys.argv[1], sys.argv[2]
p = d + '/rig/unordered.zig'; s = open(p).read()
old = """        inline fn ensureAt(self: *Self, k: K, v: V) Claim {
            var kk = k;
            var vv = v;
            const h = hashKey(rt.lend(&kk));
"""
new = """        /// The slot of `k` when its home group holds it: no probe, no
        /// overflow byte, no free lane kept.
        inline fn homeHit(self: *const Self, k: KeyView, hash: u64) ?*Element {
            const h = homeOf(hash, self.shift);
            var m = matchTag(load(&self.groups[h.pos]), h.vtag);
            if (m == 0) return null;
            const es = self.elements.?;
            while (m != 0) : (m &= m - 1) {
                const p = slotOf(es, h.pos, m);
                if (keyMatches(p, k)) return p;
            }
            return null;
        }

        pub inline fn ensure_value(self: *Self, k: K, v: V) *V {
            var kk = k;
            var vv = v;
            const h = hashKey(rt.lend(&kk));
            if (self.homeHit(rt.lend(&kk), h)) |p| {
                @branchHint(.likely);
                rt.dropElement(K, &kk);
                rt.dropElement(V, &vv);
                return &p.value;
            }
            const c = self.claim(rt.lend(&kk), h);
            if (!c.new) {
                rt.dropElement(K, &kk);
                rt.dropElement(V, &vv);
                return &self.elements.?[c.i].value;
            }
            self.elements.?[c.i] = makeElement(kk, vv, h);
            return &self.elements.?[c.i].value;
        }

        inline fn ensureAt(self: *Self, k: K, v: V) Claim {
            var kk = k;
            var vv = v;
            const h = hashKey(rt.lend(&kk));
            if (self.homeHit(rt.lend(&kk), h)) |p| {
                @branchHint(.likely);
                rt.dropElement(K, &kk);
                rt.dropElement(V, &vv);
                return .{ .i = indexOf(self.elements.?, p), .new = false };
            }
"""
assert old in s; s = s.replace(old, new, 1)
if mode == 'all':
    o1 = """                .tag = reduced_table[@as(u8, @truncate(t))],
                .vtag = tagVector(@truncate(t)),"""
    n1 = """                .tag = if (arch == .neon) @as(u8, @truncate(t)) | 0x80 else reduced_table[@as(u8, @truncate(t))],
                .vtag = if (arch == .neon) @splat(@as(u8, @truncate(t)) | 0x80) else tagVector(@truncate(t)),"""
    assert o1 in s; s = s.replace(o1, n1, 1)
open(p, 'w').write(s)
if mode in ('ptr', 'all'):
    p = d + '/__rig_std_prelude.zig'; s = open(p).read()
    for a, b in (('41', '42'),):
        o = """            const j: i64 = self.t.ensure(rig.take(&__rig_alive_k, k), rig.take(&__rig_alive_v, v));
            { const __rig_new_43: i64 = self.t.count(); self.len = __rig_new_43; }
            return self.t.value_mut(j);"""
        n = """            const p = self.t.ensure_value(rig.take(&__rig_alive_k, k), rig.take(&__rig_alive_v, v));
            { const __rig_new_43: i64 = self.t.count(); self.len = __rig_new_43; }
            return p;"""
        assert o in s; s = s.replace(o, n, 1)
    open(p, 'w').write(s)
