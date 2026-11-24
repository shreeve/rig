#!/bin/bash
# mktree.sh NAME [PATCH]: ~/cpuq/tmp/lastread/NAME/tree = Trig 8ad4c8b9's src and tools, with PATCH applied.
set -eu
D=~/cpuq/tmp/lastread/$1
rm -rf "$D/tree"; mkdir -p "$D/tree"
git -C ~/cpuq/worktrees/trig-main archive 8ad4c8b9 src tools | tar -x -C "$D/tree"
if [ -n "${2:-}" ]; then (cd "$D/tree" && patch -s -p1 < "$2"); fi
echo "tree $D/tree"
