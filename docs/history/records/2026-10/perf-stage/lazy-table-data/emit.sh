#!/bin/sh
# emit.sh TRIG OUT RIG: Trig's sources at TRIG checked and emitted by RIG into OUT/pkg
# (CHECK_IDS off, as Trig's release builds make it), with a stand-in zig that records its arguments.
set -eu
T=$1; out=$2; RIG=$3
rm -rf $out && mkdir -p $out/src
for x in $T/src/*/; do ln -s "$x" "$out/src/$(basename "$x")"; done
cp $T/tools/trig/main.rig $out/src/main.rig
rm $out/src/checks && mkdir $out/src/checks
sed 's/^pub CHECK_IDS = true$/pub CHECK_IDS = false/' $T/src/checks/checks.rig > $out/src/checks/checks.rig
grep -q '^pub CHECK_IDS = false$' $out/src/checks/checks.rig
printf "#!/bin/sh\necho \"\$@\" > $out/zigargs\n" > $out/fakezig; chmod +x $out/fakezig
cd $out/src
ZIG=$out/fakezig RIG_OUT_DIR=$out/pkg RIG_NO_CRASH_REPORT=1 $RIG build --release -o $out/bin $out/src/main.rig
cat $out/zigargs
