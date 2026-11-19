#!/bin/bash
# buildall.sh S: the eight placements (k = 0..7) built by the probe rig at
# S/rigsrc/bin/rig with no alignment (S/p0) and with RIG_PROBE_ALIGN = 16,
# 32, 64, 128 (S/pN).
set -e
S=$1; here=$(cd "$(dirname "$0")" && pwd)
export RIG=$S/rigsrc/bin/rig
"$here/buildk.sh" "$S/p0" 0 1 2 3 4 5 6 7
for n in 16 32 64 128; do RIG_PROBE_ALIGN=$n "$here/buildk.sh" "$S/p$n" 0 1 2 3 4 5 6 7; done
