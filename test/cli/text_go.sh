# std.utf8, std.utf16, and std.unicode's white space against Go's
# unicode/utf8, unicode/utf16, and unicode.IsSpace, which define them, on
# generated strings and every value: Go's answers are recorded in the
# case `std.utf8, std.utf16, and is_space agree with Go` of
# test/rig/std-text-go.rig.test, which tools/text_go.py writes. With
# TEXT_GO_FULL=1 and `go` installed, this checks the recorded answers are
# still Go's and compares the program's lines with Go's, line for line.
# timeout: 120
source "$ROOT/test/cli/_lib.sh"

if [[ -z ${TEXT_GO_FULL:-} ]]; then
    echo "recorded in test/rig/std-text-go.rig.test: TEXT_GO_FULL=1 compares with Go"
    exit 0
fi
if ! command -v go >/dev/null; then
    echo "go is not installed: skipped"
    exit 0
fi
python3 "$ROOT/tools/text_go.py" --check || fail "test/rig/std-text-go.rig.test is not what tools/text_go.py writes"
python3 "$ROOT/tools/text_go.py" --compare "$RIG" || fail "std.utf8, std.utf16, and is_space differ from Go"
