#!/bin/sh
# On pup: mkpgo.sh NAME [SRC]: Trig 403a823 built `rig build --release --pgo`
# as Trig ships it, by check-bisect's Rig (main's compiler and runtime),
# trained on copies of bolt-train's four projects; with SRC, the runtime
# files in SRC are copied over the package's rig/ before each zig
# build-exe (zigb). Release slots 0,5 only.
set -u
W=/zfs/worktrees/rig/runtime-unchecked
B=/zfs/worktrees/rig/check-bisect
d=$W/v/$1
mkdir -p $d
cd $B/emit/src
start=$(date +%s)
RUNTIME_SRC=${2:-} ZIG=$W/zigb RIG_OUT_DIR=$d/pkg RIG_NO_CRASH_REPORT=1 TRIG_RELEASE_SLOTS="0,5 0,5 0,5" sh /zfs/trig-pup/trial/slot.sh $B/rig/bin/rig build --release --pgo --pgo-profile=$d/trig.profdata -o $d/bin $B/emit/src/main.rig -- $W/bolt-train $d/bin > $d/build.log 2>&1
e=$?
echo "$(date +%T) pgo $1 exit=$e in $(( $(date +%s) - start )) s"
rm -rf /zfs/worktrees/rig/runtime-unchecked/v/$1/pkg/.zig-cache /zfs/worktrees/rig/runtime-unchecked/v/$1/pkg/pgo
exit $e
