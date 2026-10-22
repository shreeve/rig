#!/bin/bash
export RIG_OUT_DIR=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R3c1/outm
cmd=${2:-run}
for f in $1; do echo "== MAIN $f"; /private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R3c1/mainsrc/bin/rig $cmd $f 2>&1 | head -30; echo "exit=${PIPESTATUS[0]}"; done
