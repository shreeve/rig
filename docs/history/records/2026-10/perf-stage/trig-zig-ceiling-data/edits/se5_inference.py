import sys; sys.path.insert(0, sys.argv[1]); from sub import sub
sub('checker.zig', '''        const n: u32 = rig.rt(self.mapper_n(m));
        {
            var __rig_turns_6557: u32 = rig.tick_turns;
            var __rig_i_6558: i64 = 0;
            const __rig_end_6558: i64 = rig.lenOf(self.inference_contexts.constSlot(@as(i64, @intCast(@as(u32, n)))).*.inferences);
            while (__rig_i_6558 < __rig_end_6558) : ({ rig.turn(&__rig_turns_6557); __rig_i_6558 += 1; }) {
                const i = __rig_i_6558;
                const inference: u32 = self.inference_contexts.constSlot(@as(i64, @intCast(@as(u32, n)))).*.inferences.at(i);
                if (t == self.inference_infos.constSlot(@as(i64, @intCast(@as(u32, inference)))).*.type_parameter) {''', '''        const n: u32 = rig.rt(self.mapper_n(m));
        {
            // CEILING se5: nothing in the loop writes the context or the
            // infos before it returns, so each is read once: the context's
            // index tested once, its inferences walked with no test, and
            // the infos' base and length kept.
            const infs = self.inference_contexts.constSlot(@as(i64, @intCast(@as(u32, n)))).*.inferences.items();
            const infos = self.inference_infos.items();
            var __rig_turns_6557: u32 = rig.tick_turns;
            var __rig_i_6558: usize = 0;
            while (__rig_i_6558 < infs.len) : ({ rig.turn(&__rig_turns_6557); __rig_i_6558 += 1; }) {
                const i: i64 = @intCast(__rig_i_6558);
                const inference: u32 = infs[__rig_i_6558];
                if (t == infos[inference].type_parameter) {''')
