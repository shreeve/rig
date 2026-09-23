# Helpers sourced by the CLI tests. Each test runs in its own empty
# directory with $RIG (the compiler), $ROOT (the checkout), and
# $RIG_OUT_DIR set; it passes when it exits 0.

set -uo pipefail

fail() { echo "FAIL: $*"; exit 1; }

# expect_eq <actual> <expected> <what>
expect_eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"; }

# expect_has <text> <substring> <what>
expect_has() { grep -qF -- "$2" <<<"$1" || fail "$3: lacks [$2] in: $1"; }

# expect_rc <actual> <expected> <what>
expect_rc() { [[ "$1" -eq "$2" ]] || fail "$3: exit status $1, expected $2"; }
