# Checked lane arithmetic never depends on the vector overflow intrinsic,
# which LLVM miscompiles on aarch64 for wide byte vectors: the runtime's
# helpers and the programs rig emits agree with a scalar reference on
# every operation, lane type, and lane count, in each build mode, for
# vectors that overflow and vectors that do not. The grid's two drivers
# are test/lanes/lane_grid.py (Zig) and test/lanes/rig_grid.py (Rig).
# timeout: 1800
source "$ROOT/test/cli/_lib.sh"

jobs=${CPUQ_CORES:-2}
jobs=${jobs%%-*}

# The runtime's helpers, in Zig, in all three Zig build modes.
python3 "$ROOT/test/lanes/lane_grid.py" --impl rig --jobs "$jobs" --zig "${ZIG:-zig}" || fail "the Zig lane grid"

# The same operations as Rig programs, in debug and with --release.
python3 "$ROOT/test/lanes/rig_grid.py" "$RIG" --jobs "$jobs" || fail "the Rig lane grid in debug"
python3 "$ROOT/test/lanes/rig_grid.py" "$RIG" --release --jobs "$jobs" || fail "the Rig lane grid with --release"

# Compound assignment through every kind of place.
python3 "$ROOT/test/lanes/place_grid.py" "$RIG" --jobs "$jobs" || fail "the place grid in debug"
python3 "$ROOT/test/lanes/place_grid.py" "$RIG" --release --jobs "$jobs" || fail "the place grid with --release"
