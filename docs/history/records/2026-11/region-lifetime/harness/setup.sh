#!/bin/bash
# setup.sh: trig worktree of origin/main, tsrs 0.23.0 from the shipped package, the tid event-log Rig. Run inside cpuq.
set -eu
. ~/cpuq/tmp/setup1123/env.sh
R=~/cpuq/tmp/regionmodel; T=$R/tools
git -C ~/cpuq/worktrees/trig-main fetch -q origin
git -C ~/cpuq/worktrees/trig-main worktree add -q --detach $R/trig origin/main
git -C $R/trig log -1 --oneline
mkdir -p $R/hl $R/rel $R/tsrs
ln -sfn $R/trig $R/hl/tree; ln -sfn $R/trig $R/rel/tree
tar xzf ~/cpuq-spill/tsrs-build/shipped/tsrs-linux-x64-gnu-0.23.0-ts7.1.0-beta.tgz -C $R/tsrs
sha256sum $R/tsrs/package/tsrs ~/cpuq/tmp/heapmiss/tsrs | cut -c1-16
# rigtid (as rfrag/rigtid.sh, into this dir)
rm -rf $R/rigtid
git clone -q ~/cpuq/worktrees/rig-b4d9e7247 $R/rigtid
cd $R/rigtid; git -c advice.detachedHead=false checkout -q b4d9e7247
cp ~/cpuq/tmp/heapmiss/runtime-new.zig $R/runtime-new.zig
sed -e "7142s/self.logEvent(@intFromPtr(p), n, /self.logEvent(@intFromPtr(p), n | (@as(usize, @as(u32, @intCast(std.os.linux.gettid()))) << 32), /" \
    -e "7159s/self.logEvent(@intFromPtr(memory.ptr), new_len, /self.logEvent(@intFromPtr(memory.ptr), new_len | (@as(usize, @as(u32, @intCast(std.os.linux.gettid()))) << 32), /" \
    -e "7178s/self.logEvent(@intFromPtr(p), new_len, /self.logEvent(@intFromPtr(p), new_len | (@as(usize, @as(u32, @intCast(std.os.linux.gettid()))) << 32), /" \
    $R/runtime-new.zig > src/runtime.zig
grep -c "gettid()))) << 32" src/runtime.zig
zig build -Dnexus=$HOME/src/nexus/bin/nexus > $R/rigtid-build.out 2>&1; echo "rig rc=$?"
sed "s#^RIG=.*#RIG=$R/rigtid/bin/rig#" $T/build-hlog-tid.sh > $R/build-hlog-tid.sh; chmod +x $R/build-hlog-tid.sh
grep -n "^RIG=" $R/build-hlog-tid.sh
