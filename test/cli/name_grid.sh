# Every name a program may choose keeps its meaning in the emitted Zig:
# each of 93 names (Zig's keywords and primitives, the emitter's names,
# the hooks Zig's standard library looks up in the root module, `_`, and
# Rig's own) at each of 13 places a name stands, built as one program a
# place. Each runs sanitizer-clean and prints what its source says, or is
# rejected with the diagnostic test/names/name_grid.py lists for it.
# timeout: 900
source "$ROOT/test/cli/_lib.sh"

jobs=${CPUQ_CORES:-2}
jobs=${jobs%%-*}

python3 "$ROOT/test/names/name_grid.py" "$RIG" --jobs "$jobs" || fail "the name grid"
