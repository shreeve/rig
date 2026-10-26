#!/bin/sh
# build.sh NAME RIGDIR [RIG_ENV...]: build Rig in RIGDIR, then release trig
# from lg/trig-src with it into lg/NAME/bin; both on release slots.
set -u
L=/zfs/trig-pup/trial/lg; T=/zfs/trig-pup/trial
name=$1; rd=$2
export PATH=$HOME/.local/bin:$PATH
cd $rd && sh $T/slot.sh zig build -Dnexus=$HOME/Data/Code/nexus/bin/nexus > $L/rig-$name.log 2>&1 || { echo "rig $name failed"; tail -20 $L/rig-$name.log; exit 1; }
H=$L/$name; rm -rf $H && mkdir -p $H/out
cd $L/trig-src && RIG_OUT_DIR=$H/out RIG_NO_CRASH_REPORT=1 sh $T/slot.sh $rd/bin/rig build --release -o $H/bin $L/trig-src/main.rig > $H/build.log 2>&1 || { echo "trig $name failed"; tail -20 $H/build.log; exit 1; }
echo "built $name"
