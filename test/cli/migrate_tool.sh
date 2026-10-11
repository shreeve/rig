# tools/migrate-0.3.py rewrites a 0.2 program to 0.3.0, so that it runs,
# and a second run changes nothing.
source "$ROOT/test/cli/_lib.sh"

cat >old.rig <<'EOF2'
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
  print(label("a"), v.len, l.n, b.name)
EOF2

python3 "$ROOT/tools/migrate-0.3.py" apply . >out.txt 2>&1 || fail "migrate: $(cat out.txt)"
expect_has "$(cat out.txt)" "1 files: 1 rewritten" "the summary"
expect_has "$(cat old.rig)" "next: ^Node?" "a box"
expect_has "$(cat old.rig)" "v: List[Int] = List()" "a list"
expect_has "$(cat old.rig)" "fun label(s: ?String) -> ?String" "the read view"
cp old.rig once.txt
python3 "$ROOT/tools/migrate-0.3.py" apply . >out.txt 2>&1 || fail "migrate again: $(cat out.txt)"
expect_has "$(cat out.txt)" "0 rewritten, 1 already migrated" "idempotent"
expect_eq "$(cat old.rig)" "$(cat once.txt)" "the second run leaves the program"
rig run old.rig >out.txt 2>err.txt || fail "rig run: $(cat err.txt)"
expect_eq "$(cat out.txt)" "a 0 1 x" "the migrated program runs"
