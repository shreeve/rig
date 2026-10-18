# tools/migrate-0.3.py rewrites a 0.2 program to 0.3.0, so that it runs,
# leaves a file already written in 0.3 and any other text file as they
# are, and a second run changes nothing.
source "$ROOT/test/cli/_lib.sh"

mkdir tree
cat >tree/old.rig <<'EOF'
# A struct Node in a comment stays.
struct List
  n: Int

struct Node
  next: Box[Node]?
  name: Text

fun label(s: String) -> String
  s

sub main()
  v: Vec[Int] = Vec()
  b = Box(Node(next: none, name: Text("x")))
  l = List(n: 1)
  print(label("a"), v.len, l.n, b.name, "struct Node")
EOF
cat >tree/new.rig <<'EOF'
fun show(s: ?String) -> ?String
  s

sub main()
  text: String = String("x")
  xs: List[Int] = List()
  print(show(text), xs.len)
EOF
printf 'run it with Vec[Int] and Box[Node]\n' >tree/notes.txt
cp -R tree before

python3 "$ROOT/tools/migrate-0.3.py" apply tree >out.txt 2>&1 || fail "migrate: $(cat out.txt)"
expect_has "$(cat out.txt)" "2 files: 1 rewritten, 0 already migrated, 1 already 0.3" "the summary"
! grep -q MANUAL out.txt || fail "MANUAL: $(cat out.txt)"
old=$(cat tree/old.rig)
expect_has "$old" "obj Chain" "the program's List is renamed"
expect_has "$old" "l = Chain(n: 1)" "its constructor too"
expect_has "$old" "obj Node" "a struct"
expect_has "$old" "next: ^Node?" "a box"
expect_has "$old" "name: String" "a Text"
expect_has "$old" "v: List[Int] = List()" "a Vec becomes the built-in List"
expect_has "$old" "fun label(s: ?String) -> ?String" "the read view"
expect_has "$old" "# A struct Node in a comment stays." "a comment"
expect_has "$old" '"struct Node")' "a string"
cmp -s tree/new.rig before/new.rig || fail "the 0.3 file changed: $(cat tree/new.rig)"
cmp -s tree/notes.txt before/notes.txt || fail "the text file changed"

cp -R tree once
python3 "$ROOT/tools/migrate-0.3.py" apply tree >out.txt 2>&1 || fail "migrate again: $(cat out.txt)"
expect_has "$(cat out.txt)" "0 rewritten, 1 already migrated" "idempotent"
diff -r tree once >/dev/null || fail "the second run changed the tree: $(diff -r tree once)"

rig run tree/old.rig >out.txt 2>err.txt || fail "rig run: $(cat err.txt)"
expect_eq "$(cat out.txt)" "a 0 1 x struct Node" "the migrated program runs"
