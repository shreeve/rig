#!/bin/bash
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad
J=${CPUQ_CORES:-3}
cat "$1" | xargs -P $J -n 1 $S/rv2/run1.sh
