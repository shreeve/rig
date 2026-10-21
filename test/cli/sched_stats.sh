# RIG_SCHED_STATS=1: a program prints, as it ends, what each worker did
# (docs/internals/scheduler.md, increment 13). Local tasks run pinned
# on `main`'s worker; free CPU-bound tasks run on several workers.
source "$ROOT/test/cli/_lib.sh"

cat >spread.rig <<'EOF'
obj Node
  v: Int

fun spin(n: Int) -> Int
  total = 0
  for i in 0..n
    total = (total + i * 7) % 1000003
  total

fun keep(n: ?*Node, k: Int) -> Int
  n.v + k

sub main()
  n = *Node(v: 1)
  sum = 0
  for k in 0..20
    t = keep(?n, k)&
    sum += >t
  ts = Tasks[Int]()
  for i in 0..8
    !ts.add(spin(20000000 + i)&)
  xs = >ts
  print(sum, xs.len)
EOF
rig build -o spread spread.rig >build.log 2>&1 || fail "build spread: $(cat build.log)"
RIG_WORKERS=4 ./spread >out.txt 2>err.txt || fail "spread: exit $?: $(cat err.txt)"
expect_eq "$(cat out.txt)" "210 8" "spread's output"
expect_eq "$(grep -c '^rig: worker' err.txt)" 0 "no stats without RIG_SCHED_STATS"
RIG_SCHED_STATS=1 RIG_WORKERS=4 ./spread >out.txt 2>err.txt || fail "spread with stats: exit $?"
expect_eq "$(grep -c '^rig: worker [0-3]: ran [0-9]*, pinned [0-9]*, stole [0-9]*, slept [0-9]*$' err.txt)" 4 "a line per worker"
# The 20 local tasks, and `main` once it made one, ran pinned.
pinned=$(sed -n 's/^rig: worker [0-9]*: ran [0-9]*, pinned \([0-9]*\),.*/\1/p' err.txt | paste -sd+ - | bc)
(( pinned >= 20 )) || fail "pinned runs: $pinned, expected 20 or more: $(cat err.txt)"
# The free tasks ran on more than one worker.
busy=$(awk '/^rig: worker/ { gsub(",", ""); if ($5 > 0) n++ } END { print n }' err.txt)
(( busy >= 2 )) || fail "free tasks ran on $busy worker(s): $(cat err.txt)"
# task.workers(n), before the first task, sets how many workers run, in
# place of RIG_WORKERS.
cat >asked.rig <<'EOF'
use std.task

fun one() -> Int
  1

sub main()
  _ = task.workers(3)
  t = one()&
  print(>t)
EOF
rig build -o asked asked.rig >build.log 2>&1 || fail "build asked: $(cat build.log)"
RIG_SCHED_STATS=1 RIG_WORKERS=8 ./asked >out.txt 2>err.txt || fail "asked: exit $?"
expect_eq "$(grep -c '^rig: worker' err.txt)" 3 "workers after task.workers(3)"
exit 0
