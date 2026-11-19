#!/bin/bash
# buildk.sh W K...: build fork.rig with K never-taken prints (gen.py) for
# each K, release, into W/sK (package in W/oK), with $RIG (default the rig
# at b7bb1df1d). Run it under tools/heavy.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
RIG=${RIG:-/Users/shreeve/Data/Code/rig/.git/rig-baseline/b7bb1df1d28166dc3a28e855e10314ca2cfdea14/rig}
W=$1; shift; mkdir -p "$W"
for k in "$@"; do
  python3 "$here/gen.py" "$k" "$W/s$k.rig"
  RIG_OUT_DIR="$W/o$k" "$RIG" build --release "$W/s$k.rig" -o "$W/s$k" 2>&1 | grep -v "^$" || true
  [[ -x $W/s$k ]] || { echo "build $k failed"; exit 1; }
done
