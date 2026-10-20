# Fork-join runs in parallel: a task made, then its maker computing the
# other half in nested loops, takes about half the time of both halves
# in turn. Every loop's turns count toward a yield check, not only an
# outermost loop's, and a task left in a busy worker's run-next slot is
# taken by an idle worker (docs/concurrency/SCHEDULER.md).
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
expect_eq "$(grep -o 'rig\.turn(&' <<<"$zig" | wc -l | tr -d ' ')" 3 "yield checks in three nested loops"
expect_eq "$(grep -o 'rig\.tick_turns' <<<"$zig" | wc -l | tr -d ' ')" 1 "counts of turns in three nested loops"

cat >forkjoin.rig <<'EOF'
use std.time

fun nested(outer: Int, inner: Int) -> Int
  total = 0
  for j in 0..outer
    for i in 0..inner
      total = (total + i * 7 + j) % 1000003
  total

sub main()
  s = time.now()
  a = nested(4, 40000000)
  b = nested(4, 40000000)
  serial = s.elapsed() / 1000000
  s2 = time.now()
  t = nested(4, 40000000)&
  c = nested(4, 40000000)
  d = >t
  print(serial, s2.elapsed() / 1000000, a + b == c + d)
EOF
rig build --release=fast -o forkjoin forkjoin.rig >build.log 2>&1 || fail "build forkjoin: $(cat build.log)"
out=$(RIG_WORKERS=4 ./forkjoin) || fail "forkjoin: exit $?"
read -r serial forked same <<<"$out"
expect_eq "$same" true "fork-join's result"
(( forked * 4 < serial * 3 )) || fail "fork-join took $forked ms, both halves in turn $serial ms: it ran serially"
exit 0
