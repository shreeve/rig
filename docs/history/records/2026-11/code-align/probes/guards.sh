#!/bin/bash
# guards.sh S OUT: bench/json/guard.py and bench/hash/guard.py of the
# probe rig's source copy (S/rigsrc), with the probe rig emitting no
# alignment and align(64) (RIG_PROBE_ALIGN=64); their output in OUT-base.txt
# and OUT-a64.txt. Instruction counts: run under tools/heavy.
S=$1; OUT=$2
cd "$S/rigsrc"
for arm in base a64; do
  if [[ $arm == a64 ]]; then export RIG_PROBE_ALIGN=64; else unset RIG_PROBE_ALIGN; fi
  { python3 bench/json/guard.py; python3 bench/hash/guard.py; } > "$OUT-$arm.txt" 2>&1
done
