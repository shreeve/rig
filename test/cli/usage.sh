# --help, --version, and usage errors (exit 2 with a hint).
source "$ROOT/test/cli/_lib.sh"

out=$("$RIG" --help 2>&1); expect_rc $? 0 "--help"
for cmd in check run build test emit --facts --release -o RIG_LEAK_TRACE; do expect_has "$out" "$cmd" "--help"; done

out=$("$RIG" --version 2>&1); expect_rc $? 0 "--version"
[[ "$out" =~ ^rig\ [0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "--version printed [$out]"

out=$("$RIG" 2>&1); expect_rc $? 2 "no arguments"
expect_has "$out" "Usage:" "no arguments"

out=$("$RIG" frobnicate x.rig 2>&1); expect_rc $? 2 "unknown command"
expect_has "$out" "unknown command \`frobnicate\`" "unknown command"

out=$("$RIG" run 2>&1); expect_rc $? 2 "missing file"
expect_has "$out" "needs a .rig file" "missing file"

out=$("$RIG" check --release x.rig 2>&1); expect_rc $? 2 "--release on check"
out=$("$RIG" run -o out x.rig 2>&1); expect_rc $? 2 "-o on run"
out=$("$RIG" run --fast x.rig 2>&1); expect_rc $? 2 "unknown option"
expect_has "$out" "unknown option \`--fast\`" "unknown option"

out=$("$RIG" check missing.rig 2>&1); expect_rc $? 1 "unreadable file"

# --facts prints the facts of a program that checks, and nothing else.
out=$("$RIG" run --facts x.rig 2>&1); expect_rc $? 2 "--facts on run"
expect_has "$out" "\`--facts\` applies to check" "--facts on run"
printf 'sub main()\n  print(missing)\n' >bad.rig
"$RIG" check --facts bad.rig >facts.txt 2>err.txt; expect_rc $? 1 "--facts on a rejected program"
[[ ! -s facts.txt ]] || fail "facts printed for a rejected program: $(cat facts.txt)"
expect_has "$(cat err.txt)" "bad.rig:2:9: error: use of unbound name \`missing\`" "--facts on a rejected program"
exit 0
