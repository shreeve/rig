# A closure that omits trailing parameters gets hidden `_` parameters
# whose leaves lie past the end of the source. Every dump and listing the
# CLI has must handle them: none panics, and a diagnostic about the
# closure points into it.
source "$ROOT/test/cli/_lib.sh"

# The example of SPEC.md, "Closures" (a closure leaves out parameters).
cat >padded.rig <<'EOF2'
obj Gone
  n: Int

  drop(!self)
    print("drop", self.n)

sub each(f: ?sub(Int, Gone))
  f(1, Gone(n: 2))

sub main()
  each(|| print("none"))
  each(|i| print("i", i))
  each(|_, g| print("g", g.n))
EOF2

for mode in "check" "check --facts" "check --facts=sema" "check --facts=storage" tokens parse normalize emit; do
    # shellcheck disable=SC2086
    rig $mode padded.rig >out.txt 2>err.txt || fail "rig $mode: $(head -5 err.txt)"
    grep -q panic err.txt && fail "rig $mode panicked: $(head -5 err.txt)"
done
out=$(rig run padded.rig 2>&1) || fail "rig run: $out"
expect_has "$out" "g 2" "the run"
rig test padded.rig >/dev/null 2>&1 || fail "rig test"

# A hidden parameter reads as the empty text, at the closure's own place.
rig check --facts=sema padded.rig >facts.txt 2>&1
expect_has "$(cat facts.txt)" 'names leaf 11:8-11:8 "" _ param' "a hidden parameter spans its closure's start"

# A diagnostic inside a padded closure points into it.
cat >bad.rig <<'EOF2'
sub each(f: ?sub(Int, Int))
  f(1, 2)

sub main()
  each(|| print(missing))
EOF2
rig check bad.rig >bad.txt 2>&1; expect_rc $? 1 "a padded closure with an error"
expect_has "$(cat bad.txt)" "bad.rig:5:17: error: use of unbound name" "diagnostic inside the closure"
