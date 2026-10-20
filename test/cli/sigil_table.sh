# The six-row table of sigils, by mechanic, reads the same wherever it
# appears, and appears in README.md, WELCOME.md, docs/QUICK.md, and
# docs/learn/01-sigils.md, the places a reader meets it.
source "$ROOT/test/cli/_lib.sh"

table() { awk '/^\| Mechanic \| Sigils \|$/ { on = 1 } on && /^\|/ { print; next } on { exit }' "$1"; }

want=$(table "$ROOT/WELCOME.md")
[[ -n "$want" ]] || fail "WELCOME.md: no table of sigils by mechanic"
for f in README.md docs/QUICK.md docs/learn/01-sigils.md; do
  got=$(table "$ROOT/$f")
  [[ -n "$got" ]] || fail "$f: no table of sigils by mechanic"
done
while IFS= read -r f; do
  got=$(table "$ROOT/$f")
  [[ -z "$got" || "$got" == "$want" ]] || fail "$f: its table of sigils by mechanic differs from WELCOME.md's"
done < <(cd "$ROOT" && git ls-files '*.md')
