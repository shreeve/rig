# ctpatch.py: turn the counting copy's marker functions in checker.zig into global counters
p = "/tmp/gm2/bct/out/checker.zig"; s = open(p).read()
def rep(old, new):
    global s
    assert old in s, old[:50]; s = s.replace(old, new, 1)
rep("""    pub noinline fn ct(self: *const Checker, k: i64, n: i64) void {
        @setEvalBranchQuota(rig.eval_quota);
        _ = self;
        _ = k;
        _ = n;
        {}
    }""", """    pub noinline fn ct(self: *const Checker, k: i64, n: i64) void {
        _ = self;
        ct_counts[@intCast(k)] += n;
    }""")
rep("""    pub noinline fn ctget(self: *const Checker, k: i64) i64 {
        @setEvalBranchQuota(rig.eval_quota);
        _ = self;
        return k - k;
    }""", """    pub noinline fn ctget(self: *const Checker, k: i64) i64 {
        _ = self;
        return ct_counts[@intCast(k)];
    }""")
rep("""    pub noinline fn ctprint(self: *const Checker) void {
        @setEvalBranchQuota(rig.eval_quota);
        _ = self;
        {}
    }""", """    pub noinline fn ctprint(self: *const Checker) void {
        _ = self;
        @import("std").debug.print("CT {any}\\n", .{ct_counts});
    }""")
s += "\nvar ct_counts: [20]i64 = [_]i64{0} ** 20;\n"
open(p, "w").write(s); print("patched")
