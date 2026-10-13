# `rig check --time` prints, after any diagnostics, the time of each pass
# of the compiler summed over the program's modules, then the rest and
# the total (src/timing.zig); bench/check/guard.py reads it.
source "$ROOT/test/cli/_lib.sh"

cat >lib.rig <<'RIG'
pub fun twice(n: Int) -> Int
  n * 2
RIG
cat >main.rig <<'RIG'
use lib

sub main()
  print(lib.twice(21))
RIG
"$RIG" check --time main.rig >out.txt 2>err.txt || fail "rig check --time: $(cat err.txt)"
[[ ! -s out.txt ]] || fail "rig check --time writes to stdout: $(cat out.txt)"
passes=$(sed -E 's/ +[0-9]+\.[0-9]{3} ms$//' err.txt)
expect_eq "$passes" "lex and parse
resolve
typecheck
storage
ownership
proofs
inlining
other
total" "the passes rig check --time prints"

# Each time is a number of milliseconds, and they add up to the total.
awk '/ ms$/ { v = $(NF - 1); if ($1 == "total") t = v; else s += v } END { if (s > t + 0.01 || s < t - 0.01) exit 1 }' err.txt ||
    fail "the passes do not add up to the total: $(cat err.txt)"

# A program with errors prints them, then the times, and fails.
printf 'sub main()\n  print(nope)\n' >bad.rig
"$RIG" check --time bad.rig >/dev/null 2>bad.txt
expect_rc $? 1 "rig check --time of a program with an error"
expect_has "$(head -1 bad.txt)" "bad.rig:2:9: error:" "the diagnostic comes first"
expect_has "$(tail -1 bad.txt)" "total" "then the times"

out=$("$RIG" emit --time main.rig 2>&1)
expect_rc $? 2 "rig emit --time"
expect_has "$out" '`--time` applies to check' "rig emit --time"
