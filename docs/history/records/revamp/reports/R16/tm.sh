#!/bin/bash
# usage: t.sh file.rig  -> runs check then run
export RIG_OUT_DIR=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R16/outm
for f in "$@"; do
echo "=== $f"
/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R16/main/bin/rig check "$f" 2>&1 | head -20
if [ ${PIPESTATUS[0]} -eq 0 ]; then echo "--- run"; timeout 120 /private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R16/main/bin/rig run "$f" 2>&1 | head -40; echo "exit=${PIPESTATUS[0]}"; fi
done
