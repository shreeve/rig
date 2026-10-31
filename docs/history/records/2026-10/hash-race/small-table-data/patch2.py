import sys
d, mode = sys.argv[1], sys.argv[2]
p = d + '/rig/unordered.zig'; s = open(p).read()
s = s.replace("""        pub inline fn ensure_value(self: *Self, k: K, v: V) *V {""", """        pub const Ensured = struct { p: *V, new: bool };
        pub inline fn ensure_value(self: *Self, k: K, v: V) Ensured {""", 1)
s = s.replace("""                rt.dropElement(V, &vv);
                return &p.value;
            }""", """                rt.dropElement(V, &vv);
                return .{ .p = &p.value, .new = false };
            }""", 1)
s = s.replace("""                rt.dropElement(V, &vv);
                return &self.elements.?[c.i].value;
            }
            self.elements.?[c.i] = makeElement(kk, vv, h);
            return &self.elements.?[c.i].value;""", """                rt.dropElement(V, &vv);
                return .{ .p = &self.elements.?[c.i].value, .new = false };
            }
            self.elements.?[c.i] = makeElement(kk, vv, h);
            return .{ .p = &self.elements.?[c.i].value, .new = true };""", 1)
if mode == 'val':
    s = s.replace("""                return .{ .i = self.claimGrown(hash), .new = true };""", """                const r = grownClaim(self.*, hash);
                self.* = r.t;
                return .{ .i = r.i, .new = true };""", 1)
    s = s.replace("""        noinline fn claimGrown(self: *Self, hash: u64) usize {""", """        const GrownClaim = struct { t: Self, i: usize };
        noinline fn grownClaim(t: Self, hash: u64) GrownClaim {
            var s = t;
            const i = s.claimGrown(hash);
            return .{ .t = s, .i = i };
        }

        fn claimGrown(self: *Self, hash: u64) usize {""", 1)
    s = s.replace("""        pub fn __rig_drop(self: *Self) void {
            self.dropLive();
            freeArrays(self.elements, self.mask);
            self.* = .{};
        }""", """        pub inline fn __rig_drop(self: *Self) void {
            dropBlock(self.*);
            self.* = .{};
        }
        noinline fn dropBlock(t: Self) void {
            var s = t;
            s.dropLive();
            freeArrays(s.elements, s.mask);
        }""", 1)
    assert 'grownClaim' in s and 'dropBlock' in s
open(p, 'w').write(s)
p = d + '/__rig_std_prelude.zig'; s = open(p).read()
o = """            const p = self.t.ensure_value(rig.take(&__rig_alive_k, k), rig.take(&__rig_alive_v, v));
            { const __rig_new_43: i64 = self.t.count(); self.len = __rig_new_43; }
            return p;"""
n = """            const r = self.t.ensure_value(rig.take(&__rig_alive_k, k), rig.take(&__rig_alive_v, v));
            if (r.new) self.len += 1;
            return r.p;"""
assert o in s; s = s.replace(o, n, 1); open(p, 'w').write(s)
