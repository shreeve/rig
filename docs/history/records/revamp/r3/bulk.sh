#!/bin/bash
# bulk.sh <command...>: untimed bulk work (test/equiv.py, oracle-only
# sweeps, probe batches, fuzzing) under cpuq at normal priority, so timed
# gates go first. It takes 2 to 6 cores as they are free; pass the grant
# on, e.g. `bulk.sh python3 test/equiv.py BASE bin/rig -j '$CPUQ_CORES'` is
# wrong (no shell); use `bulk.sh sh -c 'python3 test/equiv.py BASE bin/rig -j "$CPUQ_CORES"'`.
# Set RIG_BULK_PRIORITY=low for fuzzing that should yield to everything.
exec "$(command -v cpuq || echo "$HOME/.local/bin/cpuq")" run --cores 2-6 --priority "${RIG_BULK_PRIORITY:-normal}" --label "rig-bulk:$(basename "$PWD")" -- "$@"
