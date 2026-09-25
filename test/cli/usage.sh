# --help, --version, and usage errors (exit 2 with a hint).
source "$ROOT/test/cli/_lib.sh"

# Help and the version go to stdout.
out=$("$RIG" --help 2>/dev/null); expect_rc $? 0 "--help"
for cmd in check run build test emit --facts --release -o RIG_LEAK_TRACE; do expect_has "$out" "$cmd" "--help"; done
out=$("$RIG" help 2>/dev/null); expect_rc $? 0 "help"
expect_has "$out" "Usage:" "help"

out=$("$RIG" --version 2>/dev/null); expect_rc $? 0 "--version"
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
expect_has "$out" "error: cannot read \`missing.rig\`: no such file" "unreadable file"

# The root must be a .rig file: `rig build prog` would overwrite `prog`
# with the executable. `help` after a command is a file name.
printf 'sub main()\n  print(1)\n' >prog
out=$("$RIG" build prog 2>&1); expect_rc $? 2 "a root without .rig"
expect_has "$out" "\`prog\` is not a .rig file" "a root without .rig"
expect_has "$(head -1 prog)" "sub main()" "the source survives"
cp prog q.rig
out=$("$RIG" build -o q.rig q.rig 2>&1); expect_rc $? 2 "-o naming a .rig file"
expect_has "$out" "would write the executable over a .rig file" "-o naming a .rig file"
expect_has "$(head -1 q.rig)" "sub main()" "the source survives -o"
out=$("$RIG" build -o q.RIG q.rig 2>&1); expect_rc $? 2 "-o naming a .RIG file"
expect_has "$out" "would write the executable over a .rig file" "-o naming a .RIG file"
expect_has "$(head -1 q.rig)" "sub main()" "the source survives -o in another case"
out=$("$RIG" check help 2>&1); expect_rc $? 2 "a file named help"
expect_has "$out" "\`help\` is not a .rig file" "a file named help"

# `rig tokens` prints to stdout, and stops at a lexer error with a
# diagnostic and exit status 1.
printf 'sub main()\n  x = 0777\n' >tokens.rig
"$RIG" tokens tokens.rig >tokens.txt 2>err.txt; expect_rc $? 1 "tokens of a malformed file"
expect_has "$(head -1 tokens.txt)" "sub \"sub\"" "token stream on stdout"
expect_has "$(cat err.txt)" "tokens.rig:2:7: error: a decimal number has no leading zero" "lexer error"

# --facts prints the facts of a program that checks, and nothing else.
out=$("$RIG" run --facts x.rig 2>&1); expect_rc $? 2 "--facts on run"
expect_has "$out" "\`--facts\` applies to check" "--facts on run"
printf 'sub main()\n  print(missing)\n' >bad.rig
"$RIG" check --facts bad.rig >facts.txt 2>err.txt; expect_rc $? 1 "--facts on a rejected program"
[[ ! -s facts.txt ]] || fail "facts printed for a rejected program: $(cat facts.txt)"
expect_has "$(cat err.txt)" "bad.rig:2:9: error: use of unbound name \`missing\`" "--facts on a rejected program"
exit 0
