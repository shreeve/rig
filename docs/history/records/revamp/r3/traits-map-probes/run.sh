#!/bin/sh
export RIG_OUT_DIR=$(mktemp -d /private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad/rigout.XXXX)
for f in "$@"; do echo "=== $f"; RIG_SANITIZE=1 /Users/shreeve/Data/Code/rig/bin/rig run "$f" 2>&1 | head -20; done
rm -rf "$RIG_OUT_DIR"
