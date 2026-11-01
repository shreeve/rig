#!/bin/bash
# Row 45 arms: Trig 4bc7a9a's release package from rig a32adf178, patched.
R=/zfs/worktrees/rig-rust-ports/r45
cd $R
for a in m h z g; do rm -rf p-$a; cp -a pkg p-$a; rm -rf p-$a/.zig-cache; done
# h: a new large block faults in the half its copy writes; a grow by mremap, none.
sed -i 's|prefault(h, got, likelyFilled(size - size / 4));|prefault(h, got, likelyFilled(size / 2));|; s|prefault(h, rc + old_size, likelyFilled((new_size - old_size) / 2));||' p-h/rig/alloc.zig
# z: no large block faults in ahead.
sed -i 's|prefault(h, got, likelyFilled(size - size / 4));||; s|prefault(h, rc + old_size, likelyFilled((new_size - old_size) / 2));||' p-z/rig/alloc.zig
# g: a List of 32 KiB or more grows by half again, not twice.
sed -i 's|return reallocSlice(T, buf, @max(want, 4, buf.len \*\| 2));|return reallocSlice(T, buf, @max(want, 4, if (buf.len * @sizeOf(T) >= 32 << 10) buf.len +\| buf.len / 2 else buf.len *\| 2));|' p-g/rig/runtime.zig
for a in m h z g; do diff -r pkg p-$a > d-$a.diff; echo "$a: $(grep -c '^[<>]' d-$a.diff) lines changed"; done
for a in m h z g; do
  ( cd p-$a && sh /zfs/trig-pup/trial/slot.sh zig build-exe -Osafe -fomit-frame-pointer --cache-dir .zig-cache __rig_main.zig -femit-bin=$R/trig-$a > $R/b-$a.log 2>&1; echo "exit $?" >> $R/b-$a.log ) &
  sleep 20
done
wait
echo ARMS DONE
