# Under RIG_STRICT_OPTIONALS=1, every object's optional is a tagged
# struct (`rig.Strict`), which Zig never lifts a value into and never
# tests with `orelse` or `null`: a program compiles only if emit and the
# runtime write every operation on it through the optional helpers
# (`rig.some`, `rig.somePtr`, `rig.pack`). The program below uses each
# form of an optional of an object, in concrete and generic code and
# through the runtime's generic API, and prints the same either way.
source "$ROOT/test/cli/_lib.sh"

cat >main.rig <<'EOF2'
use std.hash

error E
  bad

enum Color
  red
  green

obj Node
  id: Int = 5

obj Rec
  sym: Node? = none
  other: Node? = Node()

obj Holder[T]
  item: T?

  fun take(!self) -> T?
    <self.item

fun mk(k: Int) -> Node
  Node(id: k)

fun mkn(k: Int) -> Node!
  return E.bad if k < 0
  Node(id: k)

fun mko(k: Int) -> Node?
  Node(id: k) if k > 0 else none

fun tried[T](f: ?fun(Int) -> T!, k: Int) -> T?
  f(k) catch none

fun find(k: Int, at: Node? = none) -> Node?
  return at if k == 0
  return none if k < 0
  Node(id: k)

fun chain(r: ?Rec) -> Node?
  s = r.sym?
  Node(id: s.id + 1)

fun pick[T](x: T?, d: T) -> T
  x ?? d

fun first[T](x: T?, y: T?) -> T?
  x ?? y

fun name[T]() -> ?String
  @name(T)

fun nested(o: (Node?)?) -> Int
  if o as inner
    if inner as n
      return n.id
    return -1
  -2

sub main()
  r = Rec()
  print(r.sym, r.other, find(3), find(-1), find(0, at: Node(id: 8)), chain(?r))
  print(pick(r.sym, Node(id: 3)), pick(r.other, Node(id: 3)), first(r.sym, r.other), first[Node](none, none))
  print(nested(none), nested(Node(id: 2)), name[Node?](), name[(Node?)?](), name[List[Node?]]())
  h = Holder[Node](item: Node(id: 4))
  print((!h).take(), h.item)
  a: Node? = Node(id: 1)
  b: Node? = Node(id: 1)
  print(a == b, a == Node(id: 1), a != none, a.hash() == b.hash(), +a)
  if !a as n
    n.id += 1
  print(a)
  xs: List[Node] = List()
  !xs.push(Node(id: 1))
  !xs.push(Node(id: 2))
  print(xs.get(1), xs.get(5))
  for x in <xs
    print(x)
  ys: List[Node?] = List()
  !ys.push(none)
  !ys.push(Node(id: 7))
  while (!ys).pop() as y
    print(y)
  arr: [3]Node? = [Node(id: 1), none, Node(id: 3)]
  for x in arr
    print(x ?? Node(id: 0))
  print(arr.get(1), arr.get(2))
  print(Color.from_int(1), Color.from_int(7))
  m = hash.Map[String, Node]()
  !m.put(String("a"), Node(id: 6))
  print(m.get("a") ?? Node(id: 0), m.get("z") ?? Node(id: 0))
  r.sym = mk(1)
  pair: [2]Node? = [none, none]
  pair[0] = Node(id: 3)
  zs: List[Node?] = List()
  !zs.push(none)
  zs[0] = mk(4)
  c: *Cell[List[Node?]] = *Cell(List())
  !c.push(none)
  (!c)[0] = Node(id: 2)
  print(r.sym, pair, zs, c[0])
  e1: Node? = mkn(1) catch none
  e2: Node? = mkn(-3) catch mko(3)
  e3: Node? = mkn(-1) catch |e| Node(id: 9) if e == E.bad else none
  print(e1, e2, e3, tried(?mkn, 4), tried(?mkn, -4))
EOF2

expected='none Node(id: 5) Node(id: 3) none Node(id: 8) none
Node(id: 3) Node(id: 5) Node(id: 5) none
-2 2 Node? (Node?)? List[Node?]
Node(id: 4) none
true true true true Node(id: 1)
Node(id: 2)
Node(id: 2) none
Node(id: 1)
Node(id: 2)
Node(id: 7)
none
Node(id: 1)
Node(id: 0)
Node(id: 3)
none Node(id: 3)
.green none
Node(id: 6) Node(id: 0)
Node(id: 1) [Node(id: 3), none] [Node(id: 4)] Node(id: 2)
Node(id: 1) Node(id: 3) Node(id: 9) Node(id: 4) none'

# Only a type parameter's optional goes through the helpers by default;
# under the switch, every object's does.
RIG_STRICT_OPTIONALS= "$RIG" emit main.rig >plain.zig 2>err.txt || fail "rig emit: $(cat err.txt)"
expect_has "$(cat plain.zig)" 'item: rig.Opt(T),' "a type parameter's optional"
if grep -q 'rig.Opt(Node)' plain.zig; then fail "an object's optional goes through the helpers by default"; fi
RIG_STRICT_OPTIONALS=1 "$RIG" emit main.rig >strict.zig 2>err.txt || fail "strict rig emit: $(cat err.txt)"
expect_has "$(cat strict.zig)" 'sym: rig.Opt(Node)' "an object's optional under the switch"
expect_has "$(cat strict.zig)" 'pub const __rig_strict_optional = {};' "the object's marker"

out=$(RIG_STRICT_OPTIONALS= rig run main.rig 2>&1); expect_rc $? 0 "rig run"
expect_eq "$out" "$expected" "the program's output"
out=$(RIG_STRICT_OPTIONALS=1 rig run main.rig 2>&1); expect_rc $? 0 "strict rig run"
expect_eq "$out" "$expected" "the program's output with every object's optional a struct"
exit 0
