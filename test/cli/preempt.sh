#!/usr/bin/env bash
# Preemption by signal (RIG_PREEMPT=signal), where it is built: Linux
# x86-64, an optimized build. A pinned (local) task held on its worker
# after a preemption is not overwritten by a second one: a task that was
# not local makes a local task, so it is pinned too, then spins and is
# preempted while the first is held. The program ends and prints what it
# prints without the option.
source "$ROOT/test/cli/_lib.sh"

[[ "$(uname -sm)" == "Linux x86_64" ]] || { echo "skip: preemption is built for Linux x86-64 only"; exit 0; }

cat > hold.rig <<'RIG'
use std.task

obj Node
  v: Int

fun spinlocal(n: ?*Node, k: Int) -> Int
  total = n.v
  for i in 0..k
    total = (total + i * 7) % 1000003
  total

fun spin(k: Int) -> Int
  total = 0
  for i in 0..k
    total = (total + i * 3) % 1000003
  total

fun maker(k: Int) -> Int
  m = *Node(v: 2)
  t = spinlocal(?m, k)&
  s = spin(k)
  s + >t

sub main()
  task.workers(1)
  n = *Node(v: 1)
  q = maker(100000000)&
  p = spinlocal(?n, 100000000)&
  print(>p + >q)
RIG

off=$("$RIG" run --release=fast hold.rig 2>&1) || fail "without the option: $off"
on=$(RIG_PREEMPT=signal "$TIMEOUT_CMD" 60 "$RIG" run --release=fast hold.rig 2>&1) || fail "with the option (timeout 60 s): $on"
expect_eq "$on" "$off" "hold.rig with RIG_PREEMPT=signal"
