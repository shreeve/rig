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

# The default run is the part that fits a CI shard: the runtime's helpers
# in Zig (every build mode), and the Rig programs with --release, where the
# miscompile was. LANE_GRID_FULL=1 adds a second seed of the Zig grid and
# the debug builds of the Rig grids.
seeds=1
[[ -n "${LANE_GRID_FULL:-}" ]] && seeds=4

python3 "$ROOT/test/lanes/lane_grid.py" --impl rig --seeds "$seeds" --jobs "$jobs" --zig "${ZIG:-zig}" || fail "the Zig lane grid"

python3 "$ROOT/test/lanes/rig_grid.py" "$RIG" --release --jobs "$jobs" || fail "the Rig lane grid with --release"
python3 "$ROOT/test/lanes/place_grid.py" "$RIG" --release --jobs "$jobs" || fail "the place grid with --release"

if [[ -n "${LANE_GRID_FULL:-}" ]]; then
    python3 "$ROOT/test/lanes/rig_grid.py" "$RIG" --jobs "$jobs" || fail "the Rig lane grid in debug"
    python3 "$ROOT/test/lanes/place_grid.py" "$RIG" --jobs "$jobs" || fail "the place grid in debug"
fi
