#!/bin/sh
# build.sh NAME [HEAP_PROFILE]: release-build Trig (the mem-walk worktree, sent to
# /zfs/trig-pup/memwalk/trig) with pup's Rig and std.memwalk (RIG_STD), emitting
# with a fake zig, patching the package (patch-zig.py), then compiling on a slot.
set -e
M=/zfs/trig-pup/memwalk; d=$M/b/$1; rm -rf $d; mkdir -p $d/pack/src $d/out
for m in $M/trig/src/*/; do ln -sfn $m $d/pack/src/$(basename $m); done
cp $M/trig/tools/trig/main.rig $d/pack/src/main.rig
export PATH=$HOME/.local/bin:$PATH
printf '#!/bin/sh\necho "$@" > %s/zigargs\n' $d > $d/fakezig; chmod +x $d/fakezig
cd $d/pack/src
RIG_HEAP_PROFILE=${2:-} RIG_STD=$M/std ZIG=$d/fakezig RIG_OUT_DIR=$d/out /zfs/trig-pup/rig/bin/rig build --release -o $d/bin $d/pack/src/main.rig > $d/emit.log 2>&1 || true
cat $d/zigargs
python3 $M/patch-zig.py $d/out
cd $d/out
sh /zfs/trig-pup/trial/slot.sh zig $(cat $d/zigargs) > $d/build.log 2>&1
ls -la $d/bin* 2>/dev/null; tail -3 $d/build.log
