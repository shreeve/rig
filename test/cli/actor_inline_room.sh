#!/usr/bin/env bash
# timeout: 120
# An actor's method runs inline on its caller's stack only when that
# stack has as much room left as the actor's own task would give the
# method (`tasks.roomInline`). A method with no proven bound recurses
# about 70% of a task's stack deep, which fits the actor's own task;
# called by a task that has already used about 45% of its stack, with the
# actor idle, it must not run inline, where it would run out of stack.
# The same holds for `main`, whose stack is mapped as a task's is: past
# the extra 1 MiB it must not run the method inline either, and short of
# it, as a task there, it does, with no message to the actor's task.
# The depths are found by running the recursion alone, so the case holds
# whatever a frame takes on the target.
source "$ROOT/test/cli/_lib.sh"

cat >deep.rig <<'RIG'
use std.os
use std.text

# The same recursion for the caller's use of its stack and the method's,
# so both take the same frames.
fun deep(k: Int, a: (?*Actor[Deep])?, need: Int) -> Int
  if k == 0
    if a as h
      return h.go(need)
    return 0
  x = deep(k - 1, a, need)
  x + 1

obj Deep
  calls: Int

  fun go(?@, k: Int) -> Int
    deep(k, none, 0) + @calls

fun arg(i: Int) -> Int
  text.parse_int(os.args()[i]) catch 0

sub main()
  mode = os.args()[1]
  if mode == "alone"
    # The recursion alone, on a task: no actor.
    t = deep(arg(2), none, 0)&
    print(>t)
  else if mode == "main"
    # Called by `main` once it has used part of its stack.
    a = *Actor(Deep(calls: 0))
    print(deep(arg(2), ?a, arg(3)))
  else if mode == "calls"
    # Called by `main` with its stack all but unused: inline each time.
    a = *Actor(Deep(calls: 0))
    total = 0
    for _ in 0..arg(2)
      total += a.go(1)
    print(total)
  else
    a = *Actor(Deep(calls: 0))
    # Alone on the actor's own task the method fits.
    print(a.go(arg(3)))
    # Called by a task that has used part of its stack, the actor idle.
    t = deep(arg(2), ?a, arg(3))&
    print(>t)
RIG
rig build --release -o deep deep.rig >build.txt 2>&1 || fail "build deep.rig: $(cat build.txt)"

# The deepest recursion a task's stack holds, to within 1%.
lo=1000; hi=1000
while (./deep alone $hi) >/dev/null 2>&1; do lo=$hi; hi=$(( hi * 2 )); (( hi < 100000000 )) || fail "no overflow found"; done
while (( hi - lo > lo / 100 )); do
    mid=$(( (lo + hi) / 2 ))
    if (./deep alone $mid) >/dev/null 2>&1; then lo=$mid; else hi=$mid; fi
done
burn=$(( lo * 45 / 100 ))
need=$(( lo * 70 / 100 ))
for run in 1 2 3; do
    out=$(./deep call $burn $need 2>err.txt) || fail "run $run: the method ran out of stack inline (burn $burn, need $need, deepest $lo): $(tail -2 err.txt)"
    expect_eq "$out" "$need
$(( burn + need ))" "run $run"
done
out=$(RIG_SEED=5 ./deep call $burn $need 2>err.txt) || fail "seeded: the method ran out of stack inline: $(tail -2 err.txt)"
expect_eq "$out" "$need
$(( burn + need ))" "seeded"
out=$(./deep main $burn $need 2>err.txt) || fail "main: the method ran out of stack inline (burn $burn, need $need, deepest $lo): $(tail -2 err.txt)"
expect_eq "$out" "$(( burn + need ))" "main"

# Each call a message would run the actor's task once; run inline, none
# does, and the fibers the workers ran are `main` and a few of the
# runtime's.
out=$(RIG_SCHED_STATS=1 ./deep calls 1000 2>stats.txt) || fail "calls: $(tail -2 stats.txt)"
expect_eq "$out" "1000" "calls"
ran=$(awk '/^rig: worker/ { for (i = 1; i <= NF; i++) if ($i == "ran") { n = $(i + 1); sub(",", "", n); s += n } } END { print s + 0 }' stats.txt)
(( ran < 100 )) || fail "calls: the workers ran $ran fibers for 1000 calls from main, so the calls went as messages: $(cat stats.txt)"
