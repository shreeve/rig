#!/bin/sh
# mkpkg.sh DIR...: build each emitted-package copy as rig build --release=fast does
cd "$(dirname "$0")"
for d in "$@"; do zig build-exe -Ofast -fomit-frame-pointer --cache-dir $d/.zig-cache $d/__rig_main.zig -femit-bin=$d/kn12 || exit 1; done
