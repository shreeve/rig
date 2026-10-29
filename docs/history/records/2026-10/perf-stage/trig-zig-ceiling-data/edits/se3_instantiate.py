import sys; sys.path.insert(0, sys.argv[1]); from sub import sub
sub('checker.zig', '''    pub fn instantiate_type(self: *Checker, t: rig.SlotOf(134217728), m: rig.SlotOf(16777216)) rig.SlotOf(134217728) {
        @setEvalBranchQuota(rig.eval_quota);
        return self.instantiate_type_with_alias(t, m, 0);''', '''    pub inline fn instantiate_type(self: *Checker, t: rig.SlotOf(134217728), m: rig.SlotOf(16777216)) rig.SlotOf(134217728) {
        // CEILING se3: the exits that touch nothing, at the call; the
        // rest out of line.
        if (t == 0 or m == 0) return t;
        if (!self.could_contain_type_variables(t) and self.type_alias(t) == 0) return t;
        return self.instantiate_type_with_alias(t, m, 0);''')
