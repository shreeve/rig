#!/bin/sh
# The timing audit's builds (row 19), all on the E-cores: each line of a
# stream is NAME RIG_SHA TRIG_SHA [noprefault|migrate].
set -u
D=/zfs/worktrees/rig/timing-audit
RIGREPO=/zfs/trig-pup/full/rig
TRIGREPO=/zfs/trig-pup/full/trig
export TRIG_RELEASE_SLOTS="12,13 14,15 16,17"
export NEXUS=/zfs/rig/nexus/bin/nexus
export PATH=$HOME/.local/go/bin:$HOME/.local/bin:$PATH
T="taskset -c 12-19"
mkdir -p $D; cd $D
one() { name=$1 rsha=$2 tsha=$3 how=${4:-}
  r=$D/rig-$rsha${how:+-$how}
  if [ ! -x $r/bin/rig ]; then
    rm -rf $r; mkdir -p $r; git -C $RIGREPO archive $rsha | tar -x -C $r
    [ "$how" = nolead ] && { sed -i "s/^    return h.taken >= prefault_big or leads(h);/    return h.taken >= prefault_big;/" $r/src/alloc.zig; grep -q "^    return h.taken >= prefault_big;" $r/src/alloc.zig || { echo "$name: nolead arm NOT applied"; return; }; }
    [ "$how" = noprefault ] && sed -i 's/^const prefault_big: usize = 2 \* segment_size;/const prefault_big: usize = std.math.maxInt(usize);/' $r/src/alloc.zig && grep -q 'prefault_big: usize = std.math.maxInt' $r/src/alloc.zig || [ "$how" != noprefault ] || echo "$name: prefault arm NOT applied"
    (cd $r && $T sh /zfs/trig-pup/trial/slot.sh zig build -Dnexus=$NEXUS) > $D/build-rig-$name.log 2>&1 || { echo "$name: rig $rsha FAILED"; return; }
  fi
  s=$D/trig-$name
  if [ ! -x $s/trig ]; then
    rm -rf $s; mkdir -p $s; git -C $TRIGREPO archive $tsha | tar -x -C $s; cp $s/tools/trig/main.rig $s/src/main.rig
    [ "$how" = migrate ] && (cd $s && python3 /zfs/trig-pup/full/rig/tools/state-bounds.py --rig $r/bin/rig src/main.rig > $D/migrate-$name.log 2>&1)
    (cd $s && $T sh /zfs/trig-pup/trial/slot.sh $r/bin/rig build --release -o trig src/main.rig) > $D/build-trig-$name.log 2>&1 || { echo "$name: trig FAILED (tail of log below)"; tail -3 $D/build-trig-$name.log; return; }
  fi
  echo "$name: built $(date +%H:%M)"
}
git -C $RIGREPO fetch -q origin; git -C $TRIGREPO fetch -q origin
one "$@" > $D/one-$1.out 2>&1
