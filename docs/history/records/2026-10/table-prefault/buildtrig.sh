#!/bin/sh
# buildtrig.sh NAME RIG [ARM]: trig release (Trig main's src with
# tools/trig/main.rig) built by RIG into T/NAME/bin, on a release slot;
# ARM sets the probe's RIG_TABLE_ARM.
set -u
T=/zfs/worktrees/rig/table-prefault
name=$1; rig=$2; arm=${3:-}; src=${SRC:-trig-src}
H=$T/b/$name; rm -rf $H && mkdir -p $H && cp -a $T/$src/src $H/src && cd $H/src || exit 1
if [ -n "$arm" ]; then export RIG_TABLE_ARM=$arm; fi
RIG_OUT_DIR=$H/out RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh $rig build --release -o $H/bin $H/src/main.rig > $H/build.log 2>&1 || { echo "trig $name failed"; tail -5 $H/build.log; exit 1; }
rm -rf $H/out
echo "built $name $(md5sum < $H/bin | cut -c1-12)"
