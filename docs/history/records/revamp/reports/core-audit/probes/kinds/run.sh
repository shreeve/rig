#!/bin/sh
# Run each probe with bin/rig; write NAME.out with exit code and output.
RIG=${RIG:-/Users/shreeve/Data/Code/rig/bin/rig}
SUF=${SUF:-out}
for f in "$@"; do
  b=${f%.rig}
  ( cd "$(dirname "$f")" && timeout 120 "$RIG" run "$(basename "$f")" ) > "$b.$SUF" 2>&1
  echo "exit=$?" >> "$b.$SUF"
  echo "== $b"; cat "$b.$SUF"
done
