#!/bin/sh
# build-arms.sh: the zero-copy ceiling arms, each a release build of
# Trig libs-embed (le-pnew) by one PGO profile, through zcwrap; a build
# that found no release slot in an hour asks again.
W=/zfs/rig-work/zero-copy/le
export PATH=$HOME/.local/bin:$PATH
for arm in ${ARMS:-0 1 2}; do
  d=$W/arm$arm
  while :; do
    rm -rf $d; mkdir -p $d; cp -a $W/src-pgo $d/src
    cd $d/src
    ZC_ARM=$arm REAL_ZIG=zig ZIG=/zfs/rig-work/zero-copy/zcwrap RIG_OUT_DIR=$d/out RIG_NO_CRASH_REPORT=1 TRIG_RELEASE_SLOTS="12,13 14,15 16,17" \
      sh /zfs/trig-pup/trial/release-slot /zfs/rig-work/rig-27010375f/bin/rig build --release --pgo --pgo-profile=$W/dec-new.profdata -o $d/bin $d/src/main.rig > $d/build.log 2>&1
    e=$?
    grep -q "no release slot free after an hour" $d/build.log || break
  done
  echo "arm$arm=$e $(date +%T)" >> $W/arms-done.txt
  cat $d/out/__zc_arm >> $W/arms-done.txt 2>/dev/null
done
