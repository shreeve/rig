#!/bin/bash
# buildtrig.sh S: Trig at ~/Data/Code/trig's checkout (tools/trig/main.rig,
# CHECK_IDS false, as tools/trig/pgo builds it), `rig build --release` by
# the probe rig S/rigsrc/bin/rig, its libtrees made by tools/trig/gen-libtrees:
# S/trig/bin-base (no alignment) and S/trig/bin-a64 (RIG_PROBE_ALIGN=64).
# The source folder S/trig/src is main.rig beside links to Trig's src/.
# Run it under tools/heavy.
set -euo pipefail
S=$1; R=$S/rigsrc/bin/rig; T=~/Data/Code/trig
export RIG=$R TRIG_RIG_OVERRIDE=1 RIG_NO_CRASH_REPORT=1
RIG_OUT_DIR=$S/trig/out-base $T/tools/trig/gen-libtrees $S/trig/src $R build --release -o $S/trig/bin-base $S/trig/src/main.rig
RIG_PROBE_ALIGN=64 RIG_OUT_DIR=$S/trig/out-a64 $R build --release -o $S/trig/bin-a64 $S/trig/src/main.rig
