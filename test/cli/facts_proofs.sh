# `rig check --facts=proofs` checks the program, then prints each test of
# the root module known to pass, which emit omits (docs/INTERNALS.md,
# "Proven checks"), one per line in source order: `L:C KIND TESTS`.
source "$ROOT/test/cli/_lib.sh"

# The loops of test/behavior/proofs/swar.rig, line by line: every test in
# `skip_space`'s loop but the sign of `s[i]`, which needs `0 <= at`; in
# the loops that start at `at`, the upper bound of each access and every
# `+=`, but not the 8-byte guard's own `i + 8` or the reads' sign tests;
# and all of the loop that starts at 0 but its guard's add.
swar="$ROOT/test/behavior/proofs/swar.rig"
"$RIG" check --facts=proofs "$swar" >facts.txt 2>err.txt || fail "rig check --facts=proofs: $(cat err.txt)"
expected='11:9 index upper
12:20 + no_overflow
12:39 read lower upper
13:7 += no_overflow
15:7 += no_overflow
23:9 read upper
26:5 += no_overflow
27:32 index upper
28:5 += no_overflow
34:9 read upper
37:5 += no_overflow
46:9 read lower upper
49:5 += no_overflow'
diff <(echo "$expected") facts.txt >diff.txt || fail "the proofs of swar.rig differ (expected vs actual):
$(cat diff.txt)"
"$RIG" check --facts=proofs "$swar" >again.txt 2>/dev/null
cmp -s facts.txt again.txt || fail "two dumps of one program differ"

# Each program in test/behavior/proofs/ marks its use: `# proves: KIND
# TEST...` where a node of KIND on that line has every TEST proven, and
# `# keeps: KIND TEST...` where none of KIND has any of them, so the test
# is still made. Each program that keeps a test is one where that test
# fails, at least on one path the guard does not cover. A program of
# several modules is a directory, whose root `main.rig` holds the marks.
marked=0
for f in "$ROOT"/test/behavior/proofs/*.rig "$ROOT"/test/behavior/proofs/*/main.rig; do
    dump=$("$RIG" check --facts=proofs "$f" 2>err.txt) || fail "rig check --facts=proofs $f: $(cat err.txt)"
    while IFS= read -r m; do
        line=${m%%:*}
        rest=${m#*# }
        verb=${rest%%:*}
        read -r kind tests <<<"${rest#*: }"
        entries=$(grep -E "^$line:[0-9]+ $(printf '%s' "$kind" | sed 's/[+]/[+]/g') " <<<"$dump")
        for t in $tests; do
            case $verb in
                proves) grep -qw -- "$t" <<<"$entries" || fail "$(basename "$f"):$line: $kind $t is not proven: [$entries]" ;;
                keeps) ! grep -qw -- "$t" <<<"$entries" || fail "$(basename "$f"):$line: $kind $t is proven, but the program shows it can fail: [$entries]" ;;
            esac
        done
        marked=$((marked + 1))
    done < <(grep -nE '# (proves|keeps): ' "$f")
done
[[ $marked -ge 48 ]] || fail "only $marked marked uses in test/behavior/proofs/"

# A check of the program alone prints nothing more.
cat >plain.rig <<'EOF2'
sub main()
  print(1 + 2)
EOF2
"$RIG" check --facts=proofs plain.rig >plain.txt 2>err.txt || fail "rig check --facts=proofs plain.rig: $(cat err.txt)"
expect_eq "$(cat plain.txt)" "" "a program with nothing to prove"
