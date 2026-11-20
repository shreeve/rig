# Core §4's premise for std: a value that changes by a marked call gives
# out only views of what it never replaces or frees while a handle lives.
# The checkers see that in Rig code (a `!@` method of such a value changes
# only its Cells, and nothing views into a Cell); an `extern zig` function
# that takes one, through a view, a handle, or a box, or that gives a view
# of a type parameter's or an API object's value, is Zig they cannot see,
# so each must be listed, read, in `Checker.marked_externs`. Every std
# module is checked here, and a std copy with an unlisted one by each
# route, or with a method that grows a field it views, is rejected.
source "$ROOT/test/cli/_lib.sh"

mods=$(cd "$ROOT/std" && ls *.rig | sed -n 's/\.rig$//p' | grep -v '^__' | grep -v '^prelude$')
{ for m in $mods; do echo "use std.$m"; done; echo; echo "sub main()"; echo "  print(1)"; } >all.rig
env -u RIG_STD "$RIG" check all.rig >out.txt 2>&1 || fail "every std module: $(grep error out.txt | head -5)"

cp -R "$ROOT/std" stdcopy
cat >>stdcopy/shared.rig <<'EOF2'

api Peek
  fun n(?@) -> Int

extern zig "shared.zig"
  fun peek_raw[K, V](m: ?Map[K, V]) -> ?Int from m
  fun peek_h[K, V](m: *Map[K, V]) -> (?V)? from m
  fun peek_rh[K, V](m: ?*Map[K, V]) -> (?V)? from m
  fun peek_wh[K, V](m: !*Map[K, V]) -> (?V)? from m
  fun peek_g[T](m: ?T) -> ?Int from m
  fun peek_a(m: ?{Peek}) -> ?Int from m
  sub clear[K, V](m: ?Map[K, V])

# A Cell holder whose method grows a List field it views.
pub obj Log
  n: Cell[Int]
  items: List[Int]

  pub sub add(!@, x: Int)
    !@items.push(x)

  pub fun first(?@) -> ?Int from @
    ?@items[0]
EOF2
cat >use.rig <<'EOF2'
use std.shared

sub main()
  m = shared.Map[Int, Int].new()
  print(m.len())
EOF2
RIG_STD="$PWD/stdcopy" "$RIG" check use.rig >bad.txt 2>&1 && fail "a std copy with an unlisted view of a shared value was accepted"
out=$(cat bad.txt)
for f in peek_raw peek_h peek_rh peek_wh peek_g peek_a clear; do
  expect_has "$out" "\`$f\` takes a" "an unlisted extern, $f"
  expect_has "$out" "list \`std.shared.$f\` in \`Checker.marked_externs\`" "the fix for $f"
done
expect_has "$out" 'cannot make a write view through a shared handle' "a method that grows a field of a Cell holder"
