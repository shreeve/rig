# timeout: 900
# The inline grid's reached programs built with --release, shard 1 of 3
# (test/cli/inline_grid.sh runs the rest of the grid): shapes const ignored.
# Each must panic as its debug build does. Runs only with
# INLINE_GRID_FULL=1 (the full gates); otherwise it checks nothing.
source "$ROOT/test/cli/_lib.sh"
source "$ROOT/test/cli/_inline_grid.sh"

[[ -z "${INLINE_GRID_FULL:-}" ]] && exit 0
inline_grid_write
inline_grid_release_reached const ignored
