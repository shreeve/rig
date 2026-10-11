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

# An explicit file path is migrated (and only that file); so is a
# `.rig.tmpl`, and `scan` hints at, and never rewrites, another text file
# that spells things the old way.
mkdir -p tree
printf 'sub main()\n  v: Vec[Int] = Vec()\n  print(v.len)\n' >tree/one.rig
printf 'sub main()\n  v: Vec[Int] = Vec()\n  print(v.len)\n' >tree/other.rig
printf 'sub main()\n  t = Text("x")\n  print(t)\n' >tree/driver.rig.tmpl
printf 'run it with Vec[Int] and Box[Node]\n' >tree/notes.txt
cp tree/notes.txt notes.before

python3 "$ROOT/tools/migrate-0.3.py" scan tree >out.txt 2>&1 || fail "scan: $(cat out.txt)"
expect_has "$(cat out.txt)" "HINT tree/notes.txt:1: old spelling" "a hint for another text file"
expect_has "$(cat out.txt)" "3 files: 3 to rewrite" "scan counts the template"
expect_eq "$(cat tree/notes.txt)" "$(cat notes.before)" "scan leaves the text file"

python3 "$ROOT/tools/migrate-0.3.py" apply tree/one.rig >out.txt 2>&1 || fail "apply file: $(cat out.txt)"
expect_has "$(cat out.txt)" "1 files: 1 rewritten" "one file named"
expect_has "$(cat tree/one.rig)" "v: List[Int] = List()" "the named file is migrated"
expect_has "$(cat tree/other.rig)" "Vec[Int]" "a file not named is left"

python3 "$ROOT/tools/migrate-0.3.py" apply tree >out.txt 2>&1 || fail "apply tree: $(cat out.txt)"
expect_has "$(cat tree/driver.rig.tmpl)" 't = String("x")' "a .rig.tmpl is migrated"
expect_has "$(cat tree/other.rig)" "List[Int]" "the directory's .rig is migrated"
expect_eq "$(cat tree/notes.txt)" "$(cat notes.before)" "apply leaves the text file"

# A `for` over an iterator in a place gets its `!`.
cat >iter.rig <<'EOF2'
struct Count
  lo: Int
  hi: Int

  fun next(!self) -> Int?
    return none if self.lo >= self.hi
    n = self.lo
    self.lo += 1
    n

sub main()
  c = Count(lo: 0, hi: 3)
  for n in c
    print(n)
  for m in Count(lo: 0, hi: 1)
    print(m)
EOF2
RIG="$RIG" python3 "$ROOT/tools/migrate-0.3.py" apply iter.rig >out.txt 2>&1 || fail "apply iter: $(cat out.txt)"
expect_has "$(cat iter.rig)" "for n in !c" "the iterator in a place is advanced with !"
expect_has "$(cat iter.rig)" "for m in Count(lo: 0, hi: 1)" "a made iterator stays bare"
rig run iter.rig >out.txt 2>err.txt || fail "iter run: $(cat err.txt)"
expect_eq "$(cat out.txt | tr '\n' ' ')" "0 1 2 0 " "the migrated loops run"

# A file already written in 0.3 is never rewritten: not by name, not in a
# directory beside a 0.2 file, and `scan` says so. `--force` overrides.
mkdir -p mixed
printf 'sub main()\n  v: Vec[Int] = Vec()\n  print(v.len)\n' >mixed/old.rig
cat >mixed/new.rig <<'EOF2'
fun show(s: ?String) -> ?String
  s

sub main()
  text: String = String("x")
  xs: List[Int] = List()
  print(show(text), xs.len)
EOF2
cp mixed/new.rig new.before
python3 "$ROOT/tools/migrate-0.3.py" scan mixed >out.txt 2>&1 || fail "scan mixed: $(cat out.txt)"
expect_has "$(cat out.txt)" "CURRENT mixed/new.rig: already 0.3" "scan reports the 0.3 file"
expect_has "$(cat out.txt)" "2 files: 1 to rewrite" "scan counts one to rewrite"
python3 "$ROOT/tools/migrate-0.3.py" apply mixed >out.txt 2>&1 || fail "apply mixed: $(cat out.txt)"
expect_has "$(cat out.txt)" "2 files: 1 rewritten, 0 already migrated, 1 already 0.3" "one of two migrated"
expect_has "$(cat mixed/old.rig)" "v: List[Int] = List()" "the 0.2 file is migrated"
expect_eq "$(cat mixed/new.rig)" "$(cat new.before)" "the 0.3 file is byte-identical"
! grep -q MANUAL out.txt || fail "MANUAL for a 0.3 file: $(cat out.txt)"
python3 "$ROOT/tools/migrate-0.3.py" apply mixed/new.rig >out.txt 2>&1 || fail "apply named 0.3: $(cat out.txt)"
expect_eq "$(cat mixed/new.rig)" "$(cat new.before)" "a named 0.3 file is left"
python3 "$ROOT/tools/migrate-0.3.py" apply mixed --force mixed/new.rig >out.txt 2>&1 || fail "force: $(cat out.txt)"
expect_has "$(cat mixed/new.rig)" "xs: List[Int]" "--force migrates the named file (List is not declared here)"
expect_has "$(cat mixed/new.rig)" "text: ?String" "--force rewrites the String"

# A `struct List` of a 0.2 file still becomes `Chain`.
mkdir -p own
printf 'struct List\n  n: Int\n\nsub main()\n  l = List(n: 2)\n  v: Vec[Int] = Vec()\n  print(l.n, v.len)\n' >own/a.rig
python3 "$ROOT/tools/migrate-0.3.py" apply own >out.txt 2>&1 || fail "apply own: $(cat out.txt)"
expect_has "$(cat own/a.rig)" "struct Chain" "the program's List is renamed"
expect_has "$(cat own/a.rig)" "l = Chain(n: 2)" "its constructor too"
expect_has "$(cat own/a.rig)" "v: List[Int] = List()" "Vec becomes the built-in List"
