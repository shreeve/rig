# Debug builds report leaks (count and size) and exit 1; with
# RIG_LEAK_TRACE=1 set at build time, each leaked allocation comes with
# its stack trace. Release builds do not check.
source "$ROOT/test/cli/_lib.sh"

cat >cycle.rig <<'EOF'
struct Node
  next: *Cell((*Node)?)

sub main()
  a = *Node(next: *Cell(value: none))
  a.next.set(+a)
  print("made a cycle")
EOF

"$RIG" run cycle.rig >out.txt 2>err.txt; expect_rc $? 1 "leaking program"
expect_eq "$(cat out.txt)" "made a cycle" "stdout of a leaking program"
expect_has "$(cat err.txt)" "error: rig: memory leak detected: 2 allocations" "leak report"
expect_has "$(cat err.txt)" "RIG_LEAK_TRACE=1" "hint"

RIG_LEAK_TRACE=1 "$RIG" run cycle.rig >out.txt 2>err.txt; expect_rc $? 1 "leaking program, traced"
expect_has "$(cat err.txt)" "leaked:" "traced leak report"
expect_has "$(cat err.txt)" "__rig_main.zig:" "trace into the program"

"$RIG" run --release cycle.rig >out.txt 2>err.txt; expect_rc $? 0 "release build does not leak-check"
exit 0
