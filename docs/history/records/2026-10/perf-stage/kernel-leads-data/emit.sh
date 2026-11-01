#!/bin/sh
# emit.sh ARM...: on pup, Trig's sources (W/trig) checked and emitted by
# each arm's Rig into W/pkg/ARM/pkg, with CHECK_IDS false as Trig's
# release builds (tools/trig/bolt, pgo) make it, and a stand-in zig that
# records its arguments. The Zig compile runs on the Mac (mk.sh).
set -eu
W=/zfs/worktrees/rig/kernel-leads
for a in "$@"; do
  out=$W/pkg/$a; RIG=$W/rig-$a/bin/rig
  rm -rf $out && mkdir -p $out/src
  for x in $W/trig/src/*/; do ln -s "$x" "$out/src/$(basename "$x")"; done
  cp $W/trig/tools/trig/main.rig $out/src/main.rig
  rm $out/src/checks && mkdir $out/src/checks
  sed 's/^pub CHECK_IDS = true$/pub CHECK_IDS = false/' $W/trig/src/checks/checks.rig > $out/src/checks/checks.rig
  grep -q '^pub CHECK_IDS = false$' $out/src/checks/checks.rig
  printf "#!/bin/sh\necho \"\$@\" > $out/zigargs\n" > $out/fakezig; chmod +x $out/fakezig
  cd $out/src
  ZIG=$out/fakezig RIG_OUT_DIR=$out/pkg RIG_NO_CRASH_REPORT=1 taskset -c 12-19 $RIG build --release -o $out/bin $out/src/main.rig > $out/emit.log 2>&1
  echo "$a: $(cat $out/zigargs)"
done
