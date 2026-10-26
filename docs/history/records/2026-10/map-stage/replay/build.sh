#!/bin/sh
# build.sh [OUT_SUFFIX]: build the replay in Zig's safe mode (as Trig's
# release build is) and fast mode, against Rig's own release allocator,
# which it copies from src/alloc.zig beside replay.zig first.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../../../../../.." && pwd)
cp "$top/src/alloc.zig" "$here/alloc.zig"
zig build-exe -O ReleaseSafe -femit-bin="$here/replay-safe" "$here/replay.zig"
zig build-exe -O ReleaseFast -femit-bin="$here/replay-fast" "$here/replay.zig"
