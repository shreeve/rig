# Debug builds report leaks (count and size) and exit 1; with
# RIG_LEAK_TRACE=1 set at build time, each leaked allocation comes with
# its stack trace. Release builds do not check.
# builds: shared
source "$ROOT/test/cli/_lib.sh"

cat >cycle.rig <<'EOF'
obj Node
  next: *Cell[*Node?]

sub main()
  a = *Node(next: *Cell(none))
  !a.next.set(+a)
  print("made a cycle")
EOF

rig run cycle.rig >out.txt 2>err.txt; expect_rc $? 1 "leaking program"
expect_eq "$(cat out.txt)" "made a cycle" "stdout of a leaking program"
expect_has "$(cat err.txt)" "error: rig: memory leak detected: 2 allocations" "leak report"
expect_has "$(cat err.txt)" "RIG_LEAK_TRACE=1" "hint"

RIG_LEAK_TRACE=1 rig run cycle.rig >out.txt 2>err.txt; expect_rc $? 1 "leaking program, traced"
expect_has "$(cat err.txt)" "error(SafeAllocator): leaked" "traced leak report"
expect_has "$(cat err.txt)" "__rig_main.zig:" "trace into the program"

rig run --release cycle.rig >out.txt 2>err.txt; expect_rc $? 0 "release build does not leak-check"

# Boxes of API objects (docs/design/apis.md, Stage 4) free each value
# once, traced: dropped through the table, replaced, ended by a method
# that consumes self, and by one that fails.
cat >objects.rig <<'EOF'
error Bad
  closed

api Shape
  fun area(?@) -> Float
  fun close(<@) -> Int!Bad

obj Square: Shape
  side: Float
  name: String

  fun area(?@) -> Float
    @side * @side

  fun close(<@) -> Int!Bad
    if @side > 1.0
      return Bad.closed
    1

sub main()
  shapes: List[^{Shape}] = List()
  !shapes.push(^Square(side: 3.0, name: String("a")))
  b: ^{Shape} = ^Square(side: 1.0, name: String("b"))
  b = ^Square(side: 2.0, name: String("c"))
  n = <b.close() catch 0
  c: ^{Shape} = ^Square(side: 1.0, name: String("d"))
  print(shapes[0].area(), n, <c.close() catch 0)
EOF

RIG_LEAK_TRACE=1 RIG_SANITIZE=1 rig run objects.rig >out.txt 2>err.txt; expect_rc $? 0 "boxed objects, traced"
expect_eq "$(cat out.txt)" "9.0 0 1" "stdout of boxed objects"
expect_eq "$(grep -c leaked err.txt)" "0" "no leak of boxed objects"

# Shared and weak API objects (docs/design/apis.md, Stage 5) free each
# value once, traced: counts added and given back through the table, a
# weak handle outliving its value, a long chain dropped through the drop
# queue, and a frozen one whose last count is given back on another
# worker, under 20 seeds.
cat >shared.rig <<'EOF'
api Shape
  fun area(?@) -> Float

obj Square: Shape
  side: Float
  name: String

  fun area(?@) -> Float
    @side * @side

obj Link: Shape
  next: (*{Shape})?
  up: ~{Shape}

  fun area(?@) -> Float
    1.0

sub main()
  s: *{Shape} = *Square(side: 2.0, name: String("a"))
  shapes: List[*{Shape}] = List()
  !shapes.push(+s)
  !shapes.push(*Square(side: 3.0, name: String("b")))
  w = ~s
  v = +w
  head: (*{Shape})? = none
  for 0..1000
    head = *Link(next: <head, up: ~s)
  <s
  n = 0
  if *v as h
    n = 1
  <shapes
  <head
  gone = 0
  if *w as h
    gone = 1
  print(n, gone)
EOF
RIG_LEAK_TRACE=1 RIG_SANITIZE=1 rig run shared.rig >out.txt 2>err.txt; expect_rc $? 0 "shared objects, traced"
expect_eq "$(cat out.txt)" "1 0" "stdout of shared objects"
expect_eq "$(grep -c leaked err.txt)" "0" "no leak of shared objects"

cat >frozen.rig <<'EOF'
api Shape
  fun area(?@) -> Float

obj Square: Shape
  side: Float
  name: String

  fun area(?@) -> Float
    n = 0.0
    for 0..1000
      n += @side
    n

fun area_of(s: *{Shape + Syncs}) -> Float
  s.area()

sub main()
  s: *{Shape + Syncs} = *Frozen(Square(side: 2.0, name: String("a")))
  a = area_of(+s)&
  b = area_of(+s)&
  <s
  print(>a + >b)
EOF
RIG_LEAK_TRACE=1 RIG_SANITIZE=1 rig build -o frozen frozen.rig >build.log 2>&1 || fail "build frozen: $(cat build.log)"
for seed in $(seq 1 20); do
    out=$(RIG_SEED=$seed ./frozen 2>err.txt) || fail "frozen seed $seed: exit $?"
    expect_eq "$out" "4000.0" "frozen seed $seed"
    expect_eq "$(grep -c leaked err.txt)" "0" "no leak of a frozen object, seed $seed"
done
exit 0
