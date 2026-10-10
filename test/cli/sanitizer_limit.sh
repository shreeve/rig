# Past the number of guarded blocks the sanitizer may keep live (on
# Linux, what vm.max_map_count allows; here RIG_SANITIZE_BLOCKS), it says
# so once and hands out unguarded blocks: the program still runs, and
# leaks are still found.
source "$ROOT/test/cli/_lib.sh"

cat >many.rig <<'EOF2'
struct Node
  value: Int

sub main()
  nodes: Vec[*Node] = Vec()
  i = 0
  while i < 300
    !nodes.push(*Node(value: i))
    i += 1
  total = 0
  for n in ?nodes
    total += n.value
  print("total", total)
EOF2

export RIG_SANITIZE=1 RIG_SANITIZE_BLOCKS=50
rig run many.rig >out.txt 2>err.txt; expect_rc $? 0 "past the limit"
expect_eq "$(cat out.txt)" "total 44850" "stdout past the limit"
expect_eq "$(grep -c 'rig: sanitizer: mapping limit reached; further allocations are not guarded' err.txt)" 1 "one note"

cat >cycle.rig <<'EOF2'
struct Node
  next: *Cell[*Node?]

sub main()
  keep: Vec[*Node] = Vec()
  i = 0
  while i < 100
    !keep.push(*Node(next: *Cell(none)))
    i += 1
  a = *Node(next: *Cell(none))
  !a.next.set(+a)
  print(keep.len)
EOF2

rig run cycle.rig >out.txt 2>err.txt; expect_rc $? 1 "a leak past the limit"
expect_eq "$(cat out.txt)" "100" "stdout of the leaking program"
expect_has "$(cat err.txt)" "error: rig: memory leak detected: 2 allocations" "leak report past the limit"
exit 0
