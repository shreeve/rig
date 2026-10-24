# `rig check --facts=sema` checks the program, then prints the root module's
# expression facts, one per line and sorted, with no compiler ids.
source "$ROOT/test/cli/_lib.sh"

cat >main.rig <<'EOF2'
sub main()
  v: List[Int] = List()
  !v.push(1)
  print(v.len)
EOF2

"$RIG" check --facts=sema main.rig >facts.txt 2>err.txt || fail "rig check --facts=sema: $(cat err.txt)"
out=$(cat facts.txt)
expect_has "$out" 'names leaf 2:3-2:4 "v" v local' "a name's symbol"
expect_has "$out" 'types leaf 4:9-4:10 "v" List[Int]' "an expression's type"
expect_has "$out" 'scopes block 2:3-5:1' "a scope"
"$RIG" check --facts=sema main.rig >again.txt 2>/dev/null
cmp -s facts.txt again.txt || fail "two dumps of one program differ"

cat >payload.rig <<'EOF2'
enum Opt[T]
  some(v: T)
  nothing

sub main()
  t = String("t")
  match Opt.some(v: ?t)
    .some(v) => print(v)
    .nothing => pass
EOF2
"$RIG" check --facts=sema payload.rig >payload.txt 2>err.txt || fail "rig check --facts=sema payload.rig: $(cat err.txt)"
expect_has "$(cat payload.txt)" 'payload_fields leaf 8:11-8:12 "v" ?String' "a payload field's type at the instance"

# Each value that becomes an optional where it goes: `none`, and a `T`
# where a `T?` goes, which Zig lifts on its own.
cat >lift.rig <<'EOF2'
fun half(n: Int) -> Int?
  return none if n % 2 == 1
  n / 2

sub main()
  x: Int? = 4
  print(half(x ?? 0))
EOF2
"$RIG" check --facts=sema lift.rig >lift.txt 2>err.txt || fail "rig check --facts=sema lift.rig: $(cat err.txt)"
expect_has "$(cat lift.txt)" 'lifts leaf 2:10-2:14 "none" Int? from none' "the optional a none becomes"
expect_has "$(cat lift.txt)" 'lifts / 3:3-3:8 "n / 2" Int? from Int' "a result lifted into an optional"
expect_has "$(cat lift.txt)" 'lifts leaf 6:13-6:14 "4" Int? from Int' "a literal lifted into an optional"
if grep -q '"x ?? 0"' <(grep '^lifts' lift.txt); then fail "a value that goes where its own type goes is no lift"; fi

# A compile-time call's value, on the call.
cat >ct.rig <<'EOF2'
fun squares[n: Int] -> [n]Int
  t = [n of 0]
  for i in 0..n
    t[i] = i * i
  t

sub main()
  print(squares[3])
EOF2
"$RIG" check --facts=sema ct.rig >ct.txt 2>err.txt || fail "rig check --facts=sema ct.rig: $(cat err.txt)"
expect_has "$(cat ct.txt)" 'ct_calls ct_call 8:9-8:19 "squares[3]" [0, 1, 4]' "a compile-time call's value"

# How each method call dispatches: `direct` to the method the value's
# type declares, `static` through a witness, the bound's own or a
# conformance's (docs/design/apis.md, Stage 3).
cat >dispatch.rig <<'EOF2'
api Shape
  fun area(?@) -> Float

  fun twice(?@) -> Float
    2.0 * @area()

obj Square: Shape
  side: Float

  fun area(?@) -> Float
    @side * @side

fun total[T: Shape](x: ?T) -> Float
  x.area()

sub main()
  s = Square(side: 2.0)
  print(s.area(), s.twice(), total(?s))
EOF2
"$RIG" check --facts=sema dispatch.rig >dispatch.txt 2>err.txt || fail "rig check --facts=sema dispatch.rig: $(cat err.txt)"
out=$(cat dispatch.txt)
expect_has "$out" 'dispatch call 5:11-5:18 "@area()" static W_Self_Shape Shape.area' "a default's call through its own bound"
expect_has "$out" 'dispatch call 14:3-14:11 "x.area()" static W_T_Shape Shape.area' "a call through a bound"
expect_has "$out" 'dispatch call 18:9-18:17 "s.area()" direct' "a type's own method"
expect_has "$out" 'dispatch call 18:19-18:28 "s.twice()" static __rig_impl_Shape_Square(Square) Shape.twice' "a default on a provider"
expect_has "$out" 'generic_calls call 18:30-18:39 "total(?s)" Square witness __rig_impl_Shape_Square(Square)' "a witness among a call's compile-time arguments"

# An API object's type as `$name` names it, spelled as Rig writes it.
cat >object.rig <<'EOF2'
api Shape
  fun area(?@) -> Float

type Shown = ?{Shape + Print}

sub main()
  print($name(Shown))
EOF2
"$RIG" check --facts=sema object.rig >object.txt 2>err.txt || fail "rig check --facts=sema object.rig: $(cat err.txt)"
expect_has "$(cat object.txt)" 'types leaf 7:15-7:20 "Shown" ?{Shape + Print}' "an API object's type"

# A value erased to an API object, and a call through its table
# (docs/design/apis.md, Stage 4).
cat >erase.rig <<'EOF2'
api Shape
  fun area(?@) -> Float

obj Square: Shape
  side: Float

  fun area(?@) -> Float
    @side * @side

fun area_of(s: ?{Shape}) -> Float
  s.area()

fun twice(p: ?Square) -> Float
  s: ?{Shape} = p
  2.0 * s.area()

sub main()
  sq = Square(side: 2.0)
  print(area_of(sq), twice(?sq))
EOF2
"$RIG" check --facts=sema erase.rig >erase.txt 2>err.txt || fail "rig check --facts=sema erase.rig: $(cat err.txt)"
out=$(cat erase.txt)
expect_has "$out" 'dispatch call 11:3-11:11 "s.area()" dynamic Shape.area slot 0' "a call through an API object"
expect_has "$out" 'erasures leaf 19:17-19:19 "sq" Square ?{Shape} __rig_impl_Shape_Square(Square)' "an erasure"
expect_has "$out" 'erasures leaf 14:17-14:18 "p" Square ?{Shape} __rig_impl_Shape_Square(Square) copy' "an erasure of a view of plain data"
"$RIG" check --facts=storage erase.rig >storage.txt 2>err.txt || fail "rig check --facts=storage erase.rig: $(cat err.txt)"
expect_has "$(cat storage.txt)" 'erased_copy leaf 14:17-14:18 "p" copy block' "the copy an object views, a local of its block"

# A box moved into a box of an API object, its value erased.
cat >boxes.rig <<'EOF2'
api Shape
  fun area(?@) -> Float

obj Square: Shape
  side: Float

  fun area(?@) -> Float
    @side * @side

sub main()
  c = ^Square(side: 1.0)
  b: ^{Shape} = <c
  o: ^Square? = none
  m: ^{Shape}? = <o
  print(b.area(), m == none)
EOF2
"$RIG" check --facts=sema boxes.rig >boxes.txt 2>err.txt || fail "rig check --facts=sema boxes.rig: $(cat err.txt)"
out=$(cat boxes.txt)
expect_has "$out" 'erasures move 12:17-12:19 "<c" Square ^{Shape} __rig_impl_Shape_Square(Square)' "a box erased"
expect_has "$out" 'erasures move 14:18-14:20 "<o" Square ^{Shape} __rig_impl_Shape_Square(Square) optional' "an optional box erased"

cat >bad.rig <<'EOF2'
sub main()
  print(missing)
EOF2
"$RIG" check --facts=sema bad.rig >bad.txt 2>err.txt; expect_rc $? 1 "sema of a rejected program"
[[ ! -s bad.txt ]] || fail "facts printed for a rejected program"
expect_has "$(cat err.txt)" "bad.rig:2:" "diagnostic position"
exit 0
