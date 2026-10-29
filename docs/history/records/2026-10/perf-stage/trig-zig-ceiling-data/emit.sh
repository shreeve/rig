#!/bin/sh
# On pup: Trig 403a823 checked and emitted by Rig main 099c1bff3 into
# v/main/pkg, with a stand-in zig that only records its arguments.
set -eu
W=/zfs/worktrees/rig/trig-zig-ceiling
out=$W/v/main
rm -rf $out/src $out/pkg && mkdir -p $out/src
for x in $W/trig/src/*/; do ln -s "$x" "$out/src/$(basename "$x")"; done
cp $W/trig/tools/trig/main.rig $out/src/main.rig
printf "#!/bin/sh\necho \"\$@\" > $out/zigargs\n" > $W/fakezig; chmod +x $W/fakezig
cd $out/src
ZIG=$W/fakezig RIG_OUT_DIR=$out/pkg RIG_NO_CRASH_REPORT=1 $W/rig/bin/rig build --release -o $out/bin $out/src/main.rig
cat $out/zigargs
