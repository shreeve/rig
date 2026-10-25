#!/bin/sh
# build.sh NAME COMMIT: Rig COMMIT in af/rig-NAME (release slot), then
# Trig main (af/trig: src/ with tools/trig/main.rig) with it in af/NAME/bin.
set -u
name=$1; commit=$2
A=/zfs/trig-pup/trial/af
export PATH=$HOME/.local/bin:$PATH NEXUS=/zfs/rig/nexus/bin/nexus
cd $A && rm -rf rig-$name && git -c advice.detachedHead=false clone -q /zfs/trig-pup/rig rig-$name && cd rig-$name &&
  git remote set-url origin https://github.com/shreeve/rig.git && git fetch -q origin $commit &&
  git -c advice.detachedHead=false checkout -q --detach $commit || exit 1
sh /zfs/trig-pup/trial/slot.sh zig build > $A/rig-$name.log 2>&1 || { echo "rig $name failed"; tail -5 $A/rig-$name.log; exit 1; }
H=$A/$name; rm -rf $H && mkdir -p $H/pack/src && for m in $A/trig/src/*/; do ln -sfn $m $H/pack/src/$(basename $m); done
cp $A/trig/tools/trig/main.rig $H/pack/src/main.rig
RIG_OUT_DIR=$H/out RIG_NO_CRASH_REPORT=1 sh /zfs/trig-pup/trial/slot.sh $A/rig-$name/bin/rig build --release -o $H/bin $H/pack/src/main.rig > $H/build.log 2>&1 || { echo "trig $name failed"; tail -5 $H/build.log; exit 1; }
rm -rf $H/out
echo "built $name: $(cd $A/rig-$name && git log -1 --format=%h)"
