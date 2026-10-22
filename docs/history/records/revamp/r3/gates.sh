#!/bin/bash
# gates.sh <worktree> <logprefix>: the four merge gates, in order, each with
# as many workers as the cpuq grant it runs under (CPUQ_CORES, else 2). Run
# it through heavy.sh. It stops at the first failing gate. The corpus has
# its own output directory, so the suite's cleanup (which drops the caches
# of corpus programs it sampled out) never leaves the corpus cold.
# GATES_DELTA=1 runs the suite, corpus and matrix with --delta: every
# program is checked, but one whose run passed before (the results cache,
# test/README.md) is not run again. Each gate's time goes in the summary.
W=$1; L=$2
cd "$W" || exit 1
J=${CPUQ_CORES:-2}
D=(); [ "${GATES_DELTA:-0}" = 1 ] && D=(--delta)
fail() { echo "STOPPED: $1 failed" | tee -a "$L.sum"; exit 1; }
zig build 2>&1 | tail -5
echo "gates $(git rev-parse --short HEAD) -j $J ${D[*]}" | tee -a "$L.sum"
t=$SECONDS; ./test/run -j $J "${D[@]}" > "$L.suite" 2>&1; rc=$?; echo "suite rc=$rc (-j $J, $((SECONDS - t))s)" | tee -a "$L.sum"; tail -1 "$L.suite" | tee -a "$L.sum"; [ $rc -eq 0 ] || fail suite
t=$SECONDS; RIG_TEST_OUT="$W/.zig-cache/rig-test-corpus" ./test/run -j $J "${D[@]}" corpus > "$L.corpus" 2>&1; rc=$?; echo "corpus rc=$rc (-j $J, $((SECONDS - t))s)" | tee -a "$L.sum"; tail -1 "$L.corpus" | tee -a "$L.sum"; [ $rc -eq 0 ] || fail corpus
t=$SECONDS; python3 test/matrix.py -j $J "${D[@]}" --keep "$W/.zig-cache/rig-matrix" > "$L.matrix" 2>&1; rc=$?; echo "matrix rc=$rc (-j $J, $((SECONDS - t))s)" | tee -a "$L.sum"; tail -2 "$L.matrix" | tee -a "$L.sum"; [ $rc -eq 0 ] || fail matrix
t=$SECONDS; zig build test --summary all --cache-dir "$(mktemp -d)" > "$L.unit" 2>&1; rc=$?; echo "unit rc=$rc ($((SECONDS - t))s)" | tee -a "$L.sum"; grep -E 'tests? passed|Build Summary' "$L.unit" | tail -2 | tee -a "$L.sum"; [ $rc -eq 0 ] || fail unit
