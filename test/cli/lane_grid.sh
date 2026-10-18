# Checked lane arithmetic never depends on the vector overflow intrinsic,
# which LLVM miscompiles on aarch64 for wide byte vectors: the runtime's
# helpers and the programs rig emits agree with a scalar reference, for
# vectors that overflow and vectors that do not. The grids' drivers are
# test/lanes/lane_grid.py (the runtime's helpers, in Zig), rig_grid.py
# (Rig programs), place_grid.py (lanes held in places), mask_rig_grid.py
# (every mask operation), and simd2_rig_grid.py (saturating and wrapping
# shifts and arithmetic, `lag`, `lookup`), each against its own scalar
# reference.
# timeout: 1800
source "$ROOT/test/cli/_lib.sh"

jobs=${CPUQ_CORES:-2}
jobs=${jobs%%-*}

# The default run checks the miscompile itself, where it was: byte lanes,
# of every count, in an optimized build, in the runtime's helpers and in
# the programs rig emits; and lanes held in places. It takes seconds.
# LANE_GRID_FULL=1 runs every grid whole, each built in debug and with
# --release, and takes minutes: every lane type and build mode of the
# runtime's helpers, with more seeds, and the mask and SIMD round 2 grids.
if [[ -z "${LANE_GRID_FULL:-}" ]]; then
    python3 "$ROOT/test/lanes/lane_grid.py" --impl rig --modes ReleaseSafe --types u8,i8 --jobs "$jobs" --zig "${ZIG:-zig}" || fail "the Zig lane grid"
    python3 "$ROOT/test/lanes/rig_grid.py" "$RIG" --release --jobs "$jobs" --types U8,I8 || fail "the Rig lane grid with --release"
    python3 "$ROOT/test/lanes/place_grid.py" "$RIG" --release --jobs "$jobs" || fail "the place grid with --release"
    exit 0
fi

python3 "$ROOT/test/lanes/lane_grid.py" --impl rig --seeds 4 --jobs "$jobs" --zig "${ZIG:-zig}" || fail "the Zig lane grid"
types=U8,I8,U16,I16,U32,I32,U64,I64
for release in --release ""; do
    how=${release:+with --release}
    how=${how:-in debug}
    python3 "$ROOT/test/lanes/rig_grid.py" "$RIG" $release --jobs "$jobs" --types "$types" || fail "the Rig lane grid $how"
    python3 "$ROOT/test/lanes/place_grid.py" "$RIG" $release --jobs "$jobs" || fail "the place grid $how"
    python3 "$ROOT/test/lanes/mask_rig_grid.py" "$RIG" $release --jobs "$jobs" || fail "the mask grid $how"
    python3 "$ROOT/test/lanes/simd2_rig_grid.py" "$RIG" $release --jobs "$jobs" || fail "the SIMD round 2 grid $how"
done
