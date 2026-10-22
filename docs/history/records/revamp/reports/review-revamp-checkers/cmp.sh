#!/bin/bash
# usage: cmp.sh file.rig ... ; runs revamp (new) and base (old) rig run
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/review-revamp-checkers
for f in "$@"; do
  echo "=== $f"
  echo "--- new:"; (cd $(dirname $f) && RIG_OUT_DIR=$S/out-new/$(basename $f .rig) timeout 120 $S/tree/bin/rig run $(basename $f) 2>&1 | head -25)
  if [ -z "$NOBASE" ]; then echo "--- old:"; (cd $(dirname $f) && RIG_OUT_DIR=$S/out-old/$(basename $f .rig) timeout 120 $S/base/bin/rig run $(basename $f) 2>&1 | head -12); fi
done
