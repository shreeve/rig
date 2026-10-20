# Every name a program may choose keeps its meaning in the emitted Zig:
# each of 93 names (Zig's keywords and primitives, the emitter's names,
# the hooks Zig's standard library looks up in the root module, `_`, and
# Rig's own) at each of 13 places a name stands, built as six programs:
# the eight places inside a declaration share one, and each place at a
# module's top has its own. Each runs sanitizer-clean and prints what its source says, or is
# rejected with the diagnostic test/cli/_name_grid.py lists for it: those
# are the `fail` cases of test/rig/names-name-grid.rig.test, which must be
# what _name_grid.py --cases writes.
# timeout: 120
source "$ROOT/test/cli/_lib.sh"

jobs=${CPUQ_CORES:-2}
jobs=${jobs%%-*}

python3 "$ROOT/test/cli/_name_grid.py" --cases cases.rig.test || fail "write the rejected names' cases"
cmp -s cases.rig.test "$ROOT/test/rig/names-name-grid.rig.test" ||
    fail "test/rig/names-name-grid.rig.test is not what test/cli/_name_grid.py --cases writes: run it"
python3 "$ROOT/test/cli/_name_grid.py" "$RIG" --jobs "$jobs" --out "$RIG_OUT_DIR/name_grid" || fail "the name grid"
