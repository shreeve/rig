p="checker.zig"; s=open(p).read()
old='''            .Array => {
                const sources = rig.rt(self.mapper_sources(m));
                {
                    var __rig_turns_7174: u32 = rig.tick_turns;
                    var __rig_i_7175: i64 = 0;
                    const __rig_end_7175: i64 = sources.len();
                    while (__rig_i_7175 < __rig_end_7175) : ({ rig.turn(&__rig_turns_7174); __rig_i_7175 += 1; }) {
                        const i = __rig_i_7175;
                        if (t == rig.rt(self.type_at(sources, i))) {
                            return rig.rt(self.type_at(rig.rt(self.mapper_targets(m)), i));
                        }
                    }
                }
                return t;
            },'''
new='''            .Array => {
                // CEILING n1: the sources read as one slice, its range tested
                // once, the target read with one test.
                const sources = rig.rt(self.mapper_sources(m));
                const all = self.store.type_lists.items();
                const src = all[sources.start..][0..sources.count];
                var __rig_turns_7174: u32 = rig.tick_turns;
                for (src, 0..) |s, i| {
                    rig.turn(&__rig_turns_7174);
                    if (t == s) {
                        const targets = self.mapper_targets(m);
                        return all[@as(usize, targets.start) + i];
                    }
                }
                return t;
            },'''
assert s.count(old)==1
s=s.replace(old,new); open(p,"w").write(s)
