# tools/migrate-0.3.py takes programs that v0.2.9 accepts to programs
# that main accepts, through each spelling `@` and `$` replaced: self
# (`?self`, a typed `self: P`, `self.x`), labels (`:outer for`,
# `break :outer`), builtin calls (`@size(T)`, Zig's `@intCast(x)` under
# `raw`), and `const`. The programs in test/cli/fixtures/migrate_029 are
# v0.2.9's own, named by the pass they need; each is migrated in a
# directory of its own (a directory's files are one module) and checked.
# A second run changes nothing. A test file's cases and a Markdown
# file's `rig` blocks take the same passes, and strings and comments
# keep their words.
source "$ROOT/test/cli/_lib.sh"

mkdir tree
n=0
for f in "$ROOT"/test/cli/fixtures/migrate_029/*.rig; do
    b=$(basename "$f" .rig)
    mkdir "tree/$b"
    cp "$f" "tree/$b/$b.rig"
    n=$((n + 1))
done
(( n >= 40 )) || fail "only $n fixtures"

cat >tree/doc.md <<'EOF'
# Notes

`self.x` and `:outer` in prose stay.

```rig
struct P
  x: Int

  fun get(?self) -> Int
    self.x # self.x in a comment stays

sub main()
  const p = P(x: 2)
  :outer for i in 0..3
    break :outer if i == 1
    print(p.get(), @size(Int), "self.x")
```

```rig reject
sub main()
  const a = 1
```
EOF
cat >tree/cases.rig.test <<'EOF'
test "self and a label", 3
  struct P
    n: Int

    sub bump(!self)
      self.n += 1
  p = P(n: 2)
  !p.bump()
  :outer while true
    break :outer
  p.n
EOF
cp -R tree before

python3 "$ROOT/tools/migrate-0.3.py" apply tree --force tree/*/*.rig >out.txt 2>&1 || fail "migrate: $(cat out.txt)"
expect_has "$(cat out.txt)" "43 files: 42 rewritten" "the summary"
expect_has "$(cat out.txt)" "MANUAL doc.md:19: a \`rig reject\` block" "a reject block is reported"
l=self-syntax-review-symmetry-p_kw_self_local
cmp -s "tree/$l/$l.rig" "before/$l/$l.rig" || fail "a local named self changed: $(cat "tree/$l/$l.rig")"
(( $(grep -c MANUAL out.txt) == 1 )) || fail "MANUAL: $(cat out.txt)"

for d in tree/*/; do
    b=$(basename "$d")
    (cd "$d" && "$RIG" check "$b.rig") >err.txt 2>&1 || fail "$b: $(cat err.txt)"
done

doc=$(cat tree/doc.md)
expect_has "$doc" '`self.x` and `:outer` in prose stay.' "prose"
expect_has "$doc" "  fun get(?@) -> Int" "self in a doc's block"
expect_has "$doc" "    @x # self.x in a comment stays" "a comment"
expect_has "$doc" "  p =! P(x: 2)" "a fixed binding"
expect_has "$doc" "  \$outer: for i in 0..3" "a label"
expect_has "$doc" "    break \$outer if i == 1" "a jump"
expect_has "$doc" 'print(p.get(), $size(Int), "self.x")' "a builtin, and a string"
expect_has "$doc" "  const a = 1" "the reject block"
awk '/^```rig$/{p=1; next} /^```$/{p=0} p' tree/doc.md >block.rig
"$RIG" check block.rig >err.txt 2>&1 || fail "the doc's block: $(cat err.txt)"
expect_has "$(cat tree/cases.rig.test)" "      @n += 1" "a test case"
expect_has "$(cat tree/cases.rig.test)" "  \$outer: while true" "a test case's label"

cp -R tree once
python3 "$ROOT/tools/migrate-0.3.py" apply tree >out.txt 2>&1 || fail "migrate again: $(cat out.txt)"
expect_has "$(cat out.txt)" "43 files: 0 rewritten, 41 already migrated" "idempotent"
diff -r -x .rig-migrated-0.3 tree once >/dev/null || fail "the second run changed the tree: $(diff -r tree once)"
python3 "$ROOT/tools/migrate-0.3.py" --dry-run tree/*/*.rig >out.txt 2>&1 || fail "dry run: $(cat out.txt)"
expect_has "$(cat out.txt)" "41 files: 0 to rewrite" "a dry run of the migrated tree"
diff -r tree once >/dev/null || fail "the dry run changed the tree"

python3 "$ROOT/tools/migrate-0.3.py" --dry-run before/*/*.rig >out.txt 2>&1 || fail "dry run: $(cat out.txt)"
expect_has "$(cat out.txt)" "+  fun get(?@) -> Int" "a dry run prints the diff"
diff -r -x .rig-migrated-0.3 before once >/dev/null && fail "the tree did not change"
cmp -s before/self-box-c1/self-box-c1.rig "$ROOT/test/cli/fixtures/migrate_029/self-box-c1.rig" || fail "the dry run changed a file"
