# The six-row table of sigils, by mechanic, reads the same wherever it
# appears. README.md holds the reference copy, and it also appears in
# docs/learn/00-welcome.md, docs/QUICK.md, and docs/learn/01-sigils.md,
# the places a reader meets it.
source "$ROOT/test/cli/_lib.sh"

table() { awk '/^\| Mechanic \| Sigils \|$/ { on = 1 } on && /^\|/ { print; next } on { exit }' "$1"; }

want=$(table "$ROOT/README.md")
[[ -n "$want" ]] || fail "README.md: no table of sigils by mechanic"
for f in docs/learn/00-welcome.md docs/QUICK.md docs/learn/01-sigils.md; do
  got=$(table "$ROOT/$f")
  [[ -n "$got" ]] || fail "$f: no table of sigils by mechanic"
done
# Every Markdown file Rig tracks, listed from Rig's own repository
# (tools/gitdir), never from one enclosing a plain copy, where git would
# list none of these and the test would pass having read nothing.
"$ROOT/tools/gitdir" test/cli/sigil_table.sh >/dev/null || fail "no Rig repository to list the docs from"
while IFS= read -r f; do
  got=$(table "$ROOT/$f")
  [[ -z "$got" || "$got" == "$want" ]] || fail "$f: its table of sigils by mechanic differs from README.md's"
done < <(cd "$ROOT" && git ls-files '*.md')
