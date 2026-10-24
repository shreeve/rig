# `rig check --tasks` lists each local task of the program's own modules,
# the root's first, each module's in source order: where it is made, and the part that pins it to the
# thread of the task that makes it, with the type in that part that
# cannot go to another core. A task that may run on any core is not
# listed.
source "$ROOT/test/cli/_lib.sh"

cat >lib.rig <<'RIG'
pub obj Node
  pub v: Int

fun val(n: ?*Node) -> Int
  n.v

pub fun peek(n: *Node) -> Int
  t = val(?n)&
  >t
RIG
cat >main.rig <<'RIG'
use lib

fun keep(n: *lib.Node, k: Int) -> Int
  k

fun plain(k: Int) -> Int
  k

sub main()
  n = *lib.Node(v: 1)
  p = plain(3)&
  u = keep(+n, 0)&
  # A frozen value's handle goes to any core: its task is not local.
  f = *Frozen(String("abc"))
  w = look(+f)&
  print(>p + >u + >w + lib.peek(+n))

fun look(f: *Frozen[String]) -> Int
  f.len
RIG
"$RIG" check --tasks main.rig >out.txt 2>err.txt || fail "rig check --tasks: $(cat err.txt)"
[[ ! -s err.txt ]] || fail "rig check --tasks writes to stderr: $(cat err.txt)"
expect_eq "$(cat out.txt)" 'main.rig:12:7: `keep(+n, 0)&` is local, pinned to its maker'"'"'s thread by `+n`: `*lib.Node` is a `*` handle whose count is not atomic, so two cores could change it at once
lib.rig:8:7: `val(?n)&` is local, pinned to its maker'"'"'s thread by `?n`: `?*Node` views a `*` handle whose count is not atomic, so two cores could change it at once' "the local tasks rig check --tasks lists"

# A directory module's lines each name their file, with the line and
# column in it, in the order of the files' names.
mkdir -p dir
cat >dir/a.rig <<'RIG'
sub main()
  n = *Box(v: 2)
  t = get(+n)&
  print(>t + peek(+n))
RIG
cat >dir/b.rig <<'RIG'
obj Box
  v: Int

fun get(b: *Box) -> Int
  b.v

fun peek(b: *Box) -> Int
  t = get(+b)&
  >t
RIG
"$RIG" check --tasks dir >dir.txt 2>err.txt || fail "rig check --tasks dir: $(cat err.txt)"
expect_eq "$(cat dir.txt)" 'dir/a.rig:3:7: `get(+n)&` is local, pinned to its maker'"'"'s thread by `+n`: `*Box` is a `*` handle whose count is not atomic, so two cores could change it at once
dir/b.rig:8:7: `get(+b)&` is local, pinned to its maker'"'"'s thread by `+b`: `*Box` is a `*` handle whose count is not atomic, so two cores could change it at once' "a directory module's local tasks"

# A program with no local task lists nothing.
printf 'fun one() -> Int\n  1\n\nsub main()\n  t = one()&\n  print(>t)\n' >free.rig
out=$("$RIG" check --tasks free.rig 2>&1) || fail "rig check --tasks free.rig: $out"
expect_eq "$out" "" "rig check --tasks of a program with no local task"

# A task over an API object whose braces let it cross is not local.
cat >object.rig <<'RIG'
api Job
  fun run(?@) -> Int

obj Sum: Job
  n: Int

  fun run(?@) -> Int
    @n

fun work(j: ^{Job + Sends}) -> Int
  j.run()

sub main()
  j: ^{Job + Sends} = ^Sum(n: 6)
  t = work(<j)&
  print(>t)
RIG
out=$("$RIG" check --tasks object.rig 2>&1) || fail "rig check --tasks object.rig: $out"
expect_eq "$out" "" "rig check --tasks of a task over a crossing API object"

out=$("$RIG" emit --tasks main.rig 2>&1)
expect_rc $? 2 "rig emit --tasks"
expect_has "$out" '`--tasks` applies to check' "rig emit --tasks"
