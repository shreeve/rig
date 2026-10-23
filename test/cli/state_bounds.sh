# tools/state-bounds.py writes the bounds a `pub` generic must state, from
# the fixes `rig check` reports, and checks again until none is left: a
# fix that asks for more (`[T: Num]`, then `[T: Copy + Num]`), several
# declarations in a module another imports, a type's parameter, and an
# implied bound it leaves out, and brackets over several lines with a
# comment in them. A dry run prints the diff and changes
# nothing; an error with no fix to write stops it, with status 1.
source "$ROOT/test/cli/_lib.sh"

script=$ROOT/tools/state-bounds.py
mkdir -p geo
cat >geo/stats.rig <<'RIG'
pub fun total[T](xs: ?List[T]) -> T
  s = xs[0]
  for x in ?xs[1..]
    s = s + x
  s

pub fun count[K, V](m: ?Map[K, V], k: ?K) -> Int
  m.len + (1 if m.has(k) else 0)

pub obj Pair[T]
  pub a: T
  pub b: T

  pub fun first(?@) -> T
    @a

pub fun moved[T](x: T) -> T
  x

pub fun pick[
  K,
  T,  # the element, copied out [by value]
](m: ?Map[K, Int], xs: ?List[T]) -> T
  xs[0]
RIG
cat >main.rig <<'RIG'
use geo

sub main()
  l: List[Int] = List()
  !l.push(2)
  !l.push(3)
  m: Map[Int, Int] = Map()
  p = geo.Pair(a: 4, b: 5)
  print(geo.total(?l), geo.count(?m, ?1), p.first(), geo.moved(6), geo.pick(?m, ?l))
RIG
cp geo/stats.rig before.rig

out=$("$script" --rig "$RIG" --dry-run main.rig 2>err.txt); expect_rc $? 0 "dry run"
expect_has "$out" "-pub fun total[T](xs: ?List[T]) -> T" "dry run diff"
expect_has "$out" "+pub fun total[T: Copy + Num](xs: ?List[T]) -> T" "dry run diff"
expect_has "$out" "+pub obj Pair[T: Copy]" "dry run diff"
expect_has "$(cat err.txt)" "3 type parameter(s) of 3 declaration(s) in 1 file(s) would state their bounds" "dry run count"
cmp -s geo/stats.rig before.rig || fail "a dry run changed geo/stats.rig"

"$script" --rig "$RIG" main.rig 2>err.txt || fail "state-bounds: $(cat err.txt)"
expect_has "$(cat err.txt)" "3 type parameter(s) of 3 declaration(s) in 1 file(s) state their bounds" "count"
expect_has "$(cat geo/stats.rig)" "pub fun total[T: Copy + Num](xs: ?List[T]) -> T" "rewritten"
expect_has "$(cat geo/stats.rig)" "pub fun count[K, V](m: ?Map[K, V], k: ?K) -> Int" "implied bound left out"
expect_has "$(cat geo/stats.rig)" "pub obj Pair[T: Copy]" "type rewritten"
expect_has "$(cat geo/stats.rig)" "pub fun moved[T](x: T) -> T" "nothing to state"
expect_has "$(cat geo/stats.rig)" "  T: Copy,  # the element, copied out [by value]" "brackets over lines"
out=$(rig run main.rig 2>&1); expect_rc $? 0 "the rewritten program runs"
expect_eq "$out" "5 0 4 6 2" "the rewritten program's output"

# Clean: a second run changes nothing.
"$script" --rig "$RIG" main.rig 2>err.txt || fail "second run: $(cat err.txt)"
expect_has "$(cat err.txt)" "0 type parameter(s)" "second run"

# A method call on a `T` that no API names has no fix to write.
cat >calls.rig <<'RIG'
obj Sq
  n: Int

  fun size(?@) -> Int
    @n

pub fun size_of[T](x: ?T) -> Int
  x.size()

sub main()
  print(size_of(?Sq(n: 1)))
RIG
"$script" --rig "$RIG" calls.rig >/dev/null 2>err.txt; expect_rc $? 1 "an error with no fix"
expect_has "$(cat err.txt)" "declare an API with \`size\`, and bound \`T\` by it" "the error with no fix"
