#!/bin/bash
# acc.sh RIG file -> prints "A file" or "R file"
cd /private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad/head
if "$1" check "$2" >/dev/null 2>&1; then echo "A $2"; else echo "R $2"; fi
