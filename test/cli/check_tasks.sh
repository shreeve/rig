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

# A program with no local task lists nothing.
printf 'fun one() -> Int\n  1\n\nsub main()\n  t = one()&\n  print(>t)\n' >free.rig
out=$("$RIG" check --tasks free.rig 2>&1) || fail "rig check --tasks free.rig: $out"
expect_eq "$out" "" "rig check --tasks of a program with no local task"

out=$("$RIG" emit --tasks main.rig 2>&1)
expect_rc $? 2 "rig emit --tasks"
expect_has "$out" '`--tasks` applies to check' "rig emit --tasks"
