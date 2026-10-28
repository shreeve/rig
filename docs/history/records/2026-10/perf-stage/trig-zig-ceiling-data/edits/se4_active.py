import sys; sys.path.insert(0, sys.argv[1]); from sub import sub
sub('checker.zig', '''        var i: i64 = rig.lenOf(self.active_mappers);
        {
            var __rig_turns_7236: u32 = rig.tick_turns;
            while (true) : (rig.turn(&__rig_turns_7236)) {
                if (!(i > 0)) break;
                {
                    i -= 1;
                    if (self.active_mappers.at(i) == mapper) {
                        return i;
                    }
                }
            }
        }
        return @as(i64, -1);''', '''        // CEILING se4: the List read once; `i` counts down from its
        // length and nothing writes it in the loop, so no test.
        const items = self.active_mappers.items();
        var i: usize = items.len;
        {
            var __rig_turns_7236: u32 = rig.tick_turns;
            while (i > 0) : (rig.turn(&__rig_turns_7236)) {
                i -= 1;
                if (items[i] == mapper) return @intCast(i);
            }
        }
        return @as(i64, -1);''')
