#!/usr/bin/env python3
# MEASURING ONLY: map-switch.py RIGDIR. Removes every check in the code of
# the built-in Map and Set (std/__rig_builtin.rig) when RIG_MEASURE_MAP=1:
# each Int index is written proven both ways, and each function body
# starts with @setRuntimeSafety(false) (overflow, casts). Never landed.
import sys
d = sys.argv[1]
def edit(p, a, b):
    s = open(p).read(); assert s.count(a) == 1, (p, a); open(p, 'w').write(s.replace(a, b))
E = d + '/src/emit.zig'
edit(E, '''    no_proofs: bool = false,
''', '''    no_proofs: bool = false,
    /// MEASURING ONLY: the built-in Map and Set's module, every check removed.
    measure_map: bool = false,
''')
edit(E, '''    fn provenOf(self: *Emitter, node: Sexp) facts.Proven {
        if (self.no_proofs) return .{};''', '''    fn provenOf(self: *Emitter, node: Sexp) facts.Proven {
        if (self.measure_map and node.isKind(.index)) {
            const ix = ir.Index.index(node);
            if (!ix.isKind(.@"..")) if (self.typeOf(ix)) |t| if (self.peelViews(t) == self.facts.types.int_id) {
                var p: facts.Proven = self.facts.provenOf(node);
                p.lower = true;
                p.upper = true;
                return p;
            };
        }
        if (self.no_proofs) return .{};''')
edit(E, '''    fn provenIf(self: *Emitter, node: Sexp) ?struct { tests: facts.Proven, flag: []const u8 } {
        if (self.no_proofs) return null;''', '''    fn provenIf(self: *Emitter, node: Sexp) ?struct { tests: facts.Proven, flag: []const u8 } {
        if (self.no_proofs) return null;
        if (self.measure_map and node.isKind(.index) and self.provenOf(node).lower and self.provenOf(node).upper) return null;''')
edit(E, '''            if (self.fun.cold) try self.line("@branchHint(.cold);", .{});
''', '''            if (self.fun.cold) try self.line("@branchHint(.cold);", .{});
            if (self.measure_map) try self.line("@setRuntimeSafety(false);", .{});
''')
M = d + '/src/main.zig'
edit(M, '''        em.no_proofs = env.flag("RIG_NO_PROOFS");
        em.strict_optionals''', '''        em.no_proofs = env.flag("RIG_NO_PROOFS");
        em.measure_map = env.flag("RIG_MEASURE_MAP") and std.mem.endsWith(u8, m.path, "__rig_builtin.rig");
        em.strict_optionals''')
print('patched', d)
