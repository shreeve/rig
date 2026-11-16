#!/bin/bash
# buildarm.sh NAME PATCH... : build bin/rig with the patches applied, copy to bins/rig-NAME, restore src.
set -e
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/pollers
cd /Users/shreeve/Data/Code/worktrees/rig/poller-spread
N=$1; shift
git checkout -q src
for p in "$@"; do git apply $S/$p.patch; done
tools/heavy zig build
cp bin/rig $S/bins/rig-$N
git checkout -q src
echo built $N
