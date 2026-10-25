#!/bin/sh
# stand.sh NAME...: hand-applied stand-ins on base's emitted Zig, each built on a release slot.
#   ast:   every AST record read `recs.at(n.id)` / `recs.slot(..)` with no test (Node as a Slot)
#   typed: ast, the store's span lists, Ids' lists, and the symbol lists (bindings, symbols,
#          syms, symbol_data) with no test (Span[n], Slot ids, binder symbols in one table)
S=/zfs/worktrees/rig/perf-checks
SLOT="sh /zfs/trig-pup/trial/slot.sh"
export PATH=$HOME/.local/bin:$PATH XDG_CACHE_HOME=/zfs/rig/xdg-cache
until [ -x $S/bins/base ]; do sleep 60; done
for name in "$@"; do
  d=$S/out/$name; rm -rf $d; mkdir -p $d
  (cd $S/out/base && tar cf - --exclude=.zig-cache .) | (cd $d && tar xf -)
  # unchecked reads, stand-in only: the index as a slot, no compare
  python3 - $d/rig/runtime.zig <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = "        pub inline fn atProven(self: *const Self, i: Int, comptime p: Proven) T {"
assert anchor in s
add = '''        pub inline fn atU(self: *const Self, i: anytype) T {
            return self.memConst().ptr[@as(usize, @bitCast(@as(i64, i)))];
        }
        pub inline fn slotU(self: *Self, i: anytype) *T {
            return &self.mem().ptr[@as(usize, @bitCast(@as(i64, i)))];
        }
        pub inline fn constSlotU(self: *const Self, i: anytype) *const T {
            return &self.memConst().ptr[@as(usize, @bitCast(@as(i64, i)))];
        }
'''
s = s.replace(anchor, add + anchor, 1); open(p, 'w').write(s)
PY
  sed -i -e 's/recs\.at(/recs.atU(/g' -e 's/recs\.slot(/recs.slotU(/g' $d/ast.zig
  if [ $name = typed ]; then
    sed -i -E -e 's/(_lists)\.at\(/\1.atU(/g' -e 's/(_lists)\.slot\(/\1.slotU(/g' \
      -e 's/(sym_loc|tab_loc|node_base|sym_base|tab_base)\.at\(/\1.atU(/g' \
      -e 's/\.(bindings|symbols|syms|symbol_data)\.at\(/.\1.atU(/g' \
      -e 's/\.(bindings|symbols|syms|symbol_data)\.slot\(/.\1.slotU(/g' \
      -e 's/\.(bindings|symbols|syms|symbol_data)\.constSlot\(/.\1.constSlotU(/g' $d/checker.zig
  fi
  start=$(date +%s)
  $SLOT zig build-exe -Osafe --cache-dir $d/.zig-cache $d/__rig_main.zig -femit-bin=$S/bins/$name > $S/logs/build-$name.log 2>&1
  echo "$name built in $(( $(date +%s) - start ))s, status $?" >> $S/logs/build-$name.log
  rm -rf $d/.zig-cache
done
