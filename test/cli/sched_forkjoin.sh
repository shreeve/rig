# Fork-join runs in parallel: a task made, then its maker computing the
# other half in nested loops, run at once, using about twice as much CPU
# time as wall time. Every loop's turns count toward a yield check, not only an
# outermost loop's, and a task left in a busy worker's run-next slot is
# taken by an idle worker (docs/internals/scheduler.md).
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >nest.rig <<'EOF'
fun leaf(i: Int) -> Int
  i

sub main()
  t = leaf(1)&
  total = >t
  for i in 0..3
    for j in 0..3
      for k in 0..3
        total += i * j * k
  print(total)
EOF
zig=$(rig emit nest.rig) || fail "rig emit nest.rig"
# Ranges run in strips: the outermost checks between its strips, and each
# loop inside it counts its strips' turns in the outer loop's count.
expect_eq "$(grep -o 'rig\.stripTurn(&' <<<"$zig" | wc -l | tr -d ' ')" 1 "yield checks in three nested loops"
expect_eq "$(grep -o 'rig\.turns(&' <<<"$zig" | wc -l | tr -d ' ')" 2 "strips counted in three nested loops"
expect_eq "$(grep -o 'rig\.tick_turns' <<<"$zig" | wc -l | tr -d ' ')" 1 "counts of turns in three nested loops"

cat >forkjoin.rig <<'EOF'
fun nested(outer: Int, inner: Int) -> Int
  total = 0
  for j in 0..outer
    for i in 0..inner
      total = (total + i * 7 + j) % 1000003
  total

sub main()
  t = nested(4, 60000000)&
  c = nested(4, 60000000)
  d = >t
  print(c == d)
EOF
rig build --release=fast -o forkjoin forkjoin.rig >build.log 2>&1 || fail "build forkjoin: $(cat build.log)"
# Wall time against the same run on one worker, which holds while other
# work keeps the cores busy, as the suite does: the two halves run at
# once in about half the time, and in turn in about the same. The best
# of three runs on four workers counts.
TIMEFORMAT='%R'
serial=$( { time RIG_WORKERS=1 ./forkjoin >out.txt; } 2>&1 ) || fail "forkjoin on one worker: exit $?"
expect_eq "$(cat out.txt)" true "fork-join's result on one worker"
best=
for _ in 1 2 3; do
    real=$( { time RIG_WORKERS=4 ./forkjoin >out.txt; } 2>&1 ) || fail "forkjoin: exit $?"
    expect_eq "$(cat out.txt)" true "fork-join's result"
    best=$(awk -v a="$best" -v b="$real" 'BEGIN { print (a == "" || b < a) ? b : a }')
done
awk -v p="$best" -v s="$serial" 'BEGIN { exit !(p < 0.8 * s) }' || fail "fork-join took $best s on four workers and $serial s on one: it ran serially"
exit 0
