# Helpers sourced by the CLI tests. Each test runs in its own empty
# directory with $RIG (the compiler), $ROOT (the checkout), $ZIG,
# $RIG_OUT_DIR (kept between runs; only its work/ starts empty),
# $RIG_TESTS (the cases of test/rig as files), and $TIMEOUT_CMD set; it
# passes when it exits 0.

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
# its own for each root file and each setting of the variables that
# change what rig emits, under $RIG_OUT_DIR/programs/. Zig keeps one
# cached build per root path and flags, and every program's root is
# `__rig_main.zig` in its output directory, so programs built in one
# directory, or one program built with and without RIG_LEAK_TRACE,
# evict each other and rebuild cold on every run. The harness keeps each
# program's Zig cache between runs.
rig() {
    local a v root="" dir
    for a in "$@"; do [[ $a == *.rig ]] && root=${a%.rig}; done
    dir=${root//\//_}
    for v in RIG_LEAK_TRACE RIG_NO_PROOFS RIG_SANITIZE RIG_STRICT_OPTIONALS RIG_VERIFY_PROOFS RIG_STD; do
        [[ -n ${!v:-} ]] && dir+="+$v=${!v//\//_}"
    done
    RIG_OUT_DIR="$RIG_OUT_DIR/programs/$dir" "$RIG" "$@"
}

# zig_once <output>... -- <input>... -- <zig> <args>...: a Zig command
# whose point is what it writes, not the build: it is not run again when
# every <output> is there and its last run here had the same command line,
# Zig (`zig env`, with its version), and contents of <input> (files, and
# every .zig file under a directory). The stamp is beside the first
# output, `<output>.zig-once`, so keep the outputs under $RIG_OUT_DIR,
# which lasts between runs; it is written only after Zig succeeds. Its
# status and output are Zig's when it runs.
zig_once() {
    local outs=() ins=() a f stamp sum
    while (($#)) && [[ $1 != -- ]]; do outs+=("$1"); shift; done; shift
    while (($#)) && [[ $1 != -- ]]; do ins+=("$1"); shift; done; shift
    ((${#outs[@]} && $#)) || fail "zig_once: no output or no command"
    stamp=${outs[0]}.zig-once
    sum=$({
        printf '%s\n' "$PWD" "$@"
        "$1" env 2>&1; echo "status $?"
        for a in "${ins[@]}"; do
            if [[ -d $a ]]; then find "$a" -name .zig-cache -prune -o -type f -name '*.zig' -print | LC_ALL=C sort; else echo "$a"; fi
        done | while IFS= read -r f; do printf '%s\n' "$f"; cat "$f" 2>&1; echo "status $?"; done
    } | if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi)
    if [[ -f $stamp && $(<"$stamp") == "$sum" ]]; then
        for a in "${outs[@]}"; do [[ -e $a ]] || break; done
        [[ -e $a ]] && return 0
    fi
    rm -f "$stamp"
    "$@" || return
    printf '%s\n' "$sum" >"$stamp"
}
