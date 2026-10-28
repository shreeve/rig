#!/bin/sh
# queue.sh NAME[:MODE] ...: compile each variant in turn (mk.sh).
cd /zfs/worktrees/rig/trig-zig-ceiling
for x in "$@"; do n=${x%%:*}; m=-Osafe; case $x in *:fast) m=-Ofast ;; esac; sh mk.sh $n $m; done >> builds.out 2>&1
