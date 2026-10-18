# Helpers sourced by the CLI tests. Each test runs in its own empty
# directory with $RIG (the compiler), $ROOT (the checkout), and
# $RIG_OUT_DIR set; it passes when it exits 0.

set -uo pipefail

# A test/matrix.py a test starts records nothing in the shared results
# cache.
export RIG_RESULTS_CACHE=

fail() { echo "FAIL: $*"; exit 1; }

# quiet <program> [args...]: run a built program that panics on purpose so no crash report is
# filed for it: RIG_NO_CRASH_REPORT=1 (Linux: no apport), and on macOS, where cpuq's cap answers
# crashes itself (`cpuq cap --protocol` 3 or later), under `cpuq cap --no-crash-report`, which
# keeps both the user's and the system's ReportCrash quiet. Elsewhere (CI) it runs as it is.
quiet() {
    local proto
    proto=$(cpuq cap --protocol 2>/dev/null) || proto=0
    if [[ $proto =~ ^[0-9]+$ ]] && (( proto >= 3 )); then
        RIG_NO_CRASH_REPORT=1 cpuq cap --no-crash-report -- "$@"
    else
        RIG_NO_CRASH_REPORT=1 "$@"
    fi
}

# expect_eq <actual> <expected> <what>
expect_eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"; }

# expect_has <text> <substring> <what>
expect_has() { grep -qF -- "$2" <<<"$1" || fail "$3: lacks [$2] in: $1"; }

# expect_rc <actual> <expected> <what>
expect_rc() { [[ "$1" -eq "$2" ]] || fail "$3: exit status $1, expected $2"; }

# rig <command> [options] <file.rig>: "$RIG" with an output directory of
# its own for each root file, under $RIG_OUT_DIR/programs/. Zig keeps one
# cached build per root path and flags, and every program's root is
# `__rig_main.zig` in its output directory, so programs built in one
# directory evict each other and rebuild cold on every run. The harness
# keeps each program's Zig cache between runs.
rig() {
    local a root=""
    for a in "$@"; do [[ $a == *.rig ]] && root=${a%.rig}; done
    RIG_OUT_DIR="$RIG_OUT_DIR/programs/${root//\//_}" "$RIG" "$@"
}
