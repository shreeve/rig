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
exit 0
