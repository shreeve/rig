# std.terminal against Ghostty (libghostty-vt), which defines what a
# terminal shows: Ghostty's answers are recorded in
# test/rig/std-terminal-ghostty.rig.test, which tools/terminal_ghostty.py
# writes. With TERMINAL_GHOSTTY_FULL=1, Ghostty's source ($GHOSTTY, or a
# clone), and Zig 0.16.0 ($ZIG_GHOSTTY, or mise's), this checks the
# recorded answers are still Ghostty's.
# timeout: 900
source "$ROOT/test/cli/_lib.sh"

if [[ -z ${TERMINAL_GHOSTTY_FULL:-} ]]; then
    echo "recorded in test/rig/std-terminal-ghostty.rig.test: TERMINAL_GHOSTTY_FULL=1 compares with Ghostty"
    exit 0
fi
if [[ -z ${ZIG_GHOSTTY:-} ]] && ! mise where zig@0.16.0 >/dev/null 2>&1; then
    echo "Zig 0.16.0 is not installed (set ZIG_GHOSTTY): skipped"
    exit 0
fi
python3 "$ROOT/tools/terminal_ghostty.py" --check || fail "test/rig/std-terminal-ghostty.rig.test is not what tools/terminal_ghostty.py writes"
