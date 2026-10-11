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

# A `struct List` of a 0.2 file still becomes `obj Chain`.
mkdir -p own
printf 'struct List\n  n: Int\n\nsub main()\n  l = List(n: 2)\n  v: Vec[Int] = Vec()\n  print(l.n, v.len)\n' >own/a.rig
python3 "$ROOT/tools/migrate-0.3.py" apply own >out.txt 2>&1 || fail "apply own: $(cat out.txt)"
expect_has "$(cat own/a.rig)" "obj Chain" "the program's List is renamed"
expect_has "$(cat own/a.rig)" "l = Chain(n: 2)" "its constructor too"
expect_has "$(cat own/a.rig)" "v: List[Int] = List()" "Vec becomes the built-in List"

# A `struct Name` declaration becomes `obj Name`, after `pub` and with type
# parameters or `unique`; `struct` as a name, in a comment, or in a string is
# left, and so is a file already written with `obj`.
mkdir -p objs
cat >objs/old.rig <<'EOF2'
# A struct Point in a comment stays.
pub struct Pair[T] unique
  a: T

struct Point
  x: Int

sub main()
  struct = 3
  p = Point(x: struct)
  print("struct Point", p.x, struct)
EOF2
cat >objs/new.rig <<'EOF2'
obj Point
  x: Int

sub main()
  struct = 4
  print(Point(x: struct).x)
EOF2
cp objs/new.rig objs.before
python3 "$ROOT/tools/migrate-0.3.py" apply objs >out.txt 2>&1 || fail "apply objs: $(cat out.txt)"
expect_has "$(cat out.txt)" "2 files: 1 rewritten, 0 already migrated, 1 already 0.3" "the obj file is current"
expect_has "$(cat objs/old.rig)" "pub obj Pair[T] unique" "a public generic unique struct"
expect_has "$(cat objs/old.rig)" "obj Point" "a struct"
expect_has "$(cat objs/old.rig)" "# A struct Point in a comment stays." "a comment"
expect_has "$(cat objs/old.rig)" "struct = 3" "a name"
expect_has "$(cat objs/old.rig)" 'print("struct Point", p.x, struct)' "a string and a name"
expect_eq "$(cat objs/new.rig)" "$(cat objs.before)" "the obj file is byte-identical"
(cd objs && rig run old.rig >../out.txt 2>../err.txt) || fail "obj run: $(cat err.txt)"
expect_eq "$(cat out.txt)" "struct Point 3 3" "the migrated program runs"

# Each rename is its own pass. `obj` is safe on any version and runs on
# every file; the 0.2 renames run only on a file that spells something the
# 0.2 way, never because the check fails.
M="$ROOT/tools/migrate-0.3.py"
mkdir -p passes
cat >passes/native.rig <<'EOF2'
# A struct Native in a comment, and "struct Native" in a string.
pub struct Native
  text: String
  tag: ?String

fun show(s: ?String) -> ?String
  s

fun more(s: !String) -> Int
  s.len

sub main()
  t = String("x")
  print(show(t), "struct Text")
EOF2
cat >passes/old.rig <<'EOF2'
struct Old
  name: Text
  xs: Vec[Int]
  b: Box[Old]?

fun f(s: String) -> String
  s
EOF2
cat >passes/obj.rig <<'EOF2'
obj Done
  name: String
EOF2
cp passes/obj.rig obj.before
# recorded.rig: the 0.2 renames are done (as an older run left it, struct
# still in it).
printf 'struct Rec\n  v: List[Int]\n' >passes/recorded.rig
h=$(python3 -c 'import hashlib;print(hashlib.sha256(open("passes/recorded.rig").read().encode()).hexdigest())')
printf '%s  recorded.rig\n' "$h" >passes/.rig-migrated-0.3

python3 "$M" apply passes >out.txt 2>&1 || fail "apply passes: $(cat out.txt)"
! grep -q MANUAL out.txt || fail "MANUAL: $(cat out.txt)"
# A 0.3-native file: only struct -> obj.
expect_has "$(cat passes/native.rig)" "pub obj Native" "native: obj"
expect_has "$(cat passes/native.rig)" "  text: String" "native: String kept"
expect_has "$(cat passes/native.rig)" "tag: ?String" "native: ?String kept"
expect_has "$(cat passes/native.rig)" "fun more(s: !String)" "native: !String kept"
expect_has "$(cat passes/native.rig)" "t = String(\"x\")" "native: String() kept"
expect_has "$(cat passes/native.rig)" '# A struct Native in a comment, and "struct Native" in a string.' "native: comment and string kept"
expect_has "$(cat passes/native.rig)" 'print(show(t), "struct Text")' "native: string kept"
# A recorded file still gets obj, and its 0.2 renames are not redone.
expect_eq "$(cat passes/recorded.rig)" "$(printf 'obj Rec\n  v: List[Int]')" "recorded: obj only"
# A true 0.2 file gets every rename.
expect_has "$(cat passes/old.rig)" "obj Old" "old: obj"
expect_has "$(cat passes/old.rig)" "name: String" "old: Text"
expect_has "$(cat passes/old.rig)" "xs: List[Int]" "old: Vec"
expect_has "$(cat passes/old.rig)" "b: ^Old?" "old: Box"
expect_has "$(cat passes/old.rig)" "fun f(s: ?String) -> ?String" "old: read view"
expect_eq "$(cat passes/obj.rig)" "$(cat obj.before)" "a current file is untouched"
# A second run changes nothing.
cat passes/*.rig >twice.before
python3 "$M" apply passes >out.txt 2>&1 || fail "apply passes again: $(cat out.txt)"
cat passes/*.rig >twice.after
expect_eq "$(cat twice.after)" "$(cat twice.before)" "the second run changes nothing"
expect_has "$(cat out.txt)" "0 rewritten" "the second run rewrites nothing"
