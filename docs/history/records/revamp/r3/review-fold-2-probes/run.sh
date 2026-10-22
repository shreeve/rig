#!/bin/bash
# usage: run.sh files...
R=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad/wfold2/bin/rig
export RIG_OUT_DIR=$(mktemp -d)
for f in "$@"; do
  echo "== $f"
  if out=$($R check $f 2>&1); then
    echo "-- debug"; RIG_SANITIZE=1 $R run $f 2>&1 | head -12
    echo "-- release"; $R build --release -o $RIG_OUT_DIR/p $f 2>&1 | head -5 && RIG_SANITIZE=1 $RIG_OUT_DIR/p 2>&1 | head -12
  else echo "REJECT: $(echo "$out" | head -3)"; fi
done
