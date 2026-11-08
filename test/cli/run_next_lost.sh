#!/usr/bin/env bash
# A worker keeps four "run next" fibers in a circle, and a fiber made
# ready takes the oldest's slot, which sends the oldest to the ring
# (src/sched.zig, `wakeIn`). No fiber may be lost on the way or left
# waiting. A tree of tasks, each making six (more than the slots hold)
# and waiting for them in the order made, and a chain of six tasks
# waited for newest first, count every task: on 1, 2, 4 and 8 workers,
# preempted by signal where that is built and with yield checks
# elsewhere. A lost fiber hangs its waiter, which the timeout
# catches; a miscount fails the check.
source "$ROOT/test/cli/_lib.sh"

cat > lost.rig <<'RIG'
fun tree(d: Int) -> Int
  return 1 if d == 0
  ts = Tasks[Int]()
  for 0..6
    !ts.add(tree(d - 1)&)
  n = 1
  for x in >ts
    n += x
  n

fun leaf(i: Int) -> Int
  i

fun reversed(rounds: Int) -> Int
  n = 0
  for 0..rounds
    a = leaf(1)&
    b = leaf(2)&
    c = leaf(3)&
    d = leaf(4)&
    e = leaf(5)&
    f = leaf(6)&
    n += >f + >e + >d + >c + >b + >a
  n

sub main()
  print(tree(5), reversed(2000))
RIG

"$RIG" build --release=fast -o lost-plain lost.rig >build.txt 2>&1 || fail "build lost.rig: $(cat build.txt)"
builds="plain"
for b in $builds; do
    for w in 1 2 4 8; do
        for i in 1 2 3; do
            out=$(RIG_WORKERS=$w "$TIMEOUT_CMD" 60 ./lost-$b 2>&1) || fail "lost.rig $b, $w workers, run $i (timeout 60 s): $out"
            expect_eq "$out" "9331 42000" "lost.rig $b, $w workers, run $i: every task ran once"
        done
    done
done
exit 0
