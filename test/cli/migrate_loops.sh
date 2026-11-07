# tools/migrate-loops.py rewrites `while true` to `loop` in every file a
# directory holds that is Rig code (.rig, .rig.test, .rig.tmpl, and the
# ```rig blocks of .md), and in a file named on the command line
# whatever its extension, and `while (true)` too; it flags a loop `else`
# and a name `loop`, and rewrites no other file.
source "$ROOT/test/cli/_lib.sh"

mkdir -p tree
printf 'sub main()\n  loop\n    break\n' >want.rig
printf 'sub main()\n  while true\n    break\n' >tree/a.rig
printf 'sub main()\n  while true\n    break\n' >tree/driver.rig.tmpl
printf 'sub main()\n  while true\n    break\n' >tree/notes.txt
printf 'sub main()\n  while true\n    break\n' >gen.in
printf 'sub main()\n  for x in [1]\n    print(x)\n  else\n    print(0)\n' >tree/b.rig
printf 'sub main()\n  while (true)\n    break\n' >tree/c.rig
printf 'sub loop()\n  pass\n\nsub main()\n  $l: loop\n    break $l\n' >tree/d.rig

out=$(python3 "$ROOT/tools/migrate-loops.py" --dry-run tree gen.in 2>&1) || fail "dry run: $out"
expect_has "$out" "would rewrite 4 \`while true\` in 4 files; 2 flagged" "the dry run's totals"
expect_has "$out" "tree/b.rig:4: \`else\` on a \`for\` loop" "a loop else is flagged"
expect_has "$out" "tree/d.rig:1: a name \`loop\`" "a name loop is flagged, and the keyword is not"
cmp -s tree/a.rig gen.in || fail "the dry run changed a file"

out=$(python3 "$ROOT/tools/migrate-loops.py" tree gen.in 2>&1) || fail "migrate: $out"
for f in tree/a.rig tree/c.rig tree/driver.rig.tmpl gen.in; do
    cmp -s "$f" want.rig || fail "$f not rewritten: $(cat "$f")"
done
grep -q "while true" tree/notes.txt || fail "a file the directory walk does not read changed"
(cd tree && "$RIG" check a.rig) >err.txt 2>&1 || fail "the rewritten program: $(cat err.txt)"
