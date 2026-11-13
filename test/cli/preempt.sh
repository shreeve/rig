#!/usr/bin/env bash
# Preemption by signal, the default where it is built, and local tasks.
# A program that makes a local task keeps its yield checks, since local
# tasks share counts that are not atomic and take turns at their waits
# and yield checks: its functions are not placed in the program's
# section, and it ends: tasks that spin-wait on each other, local ones
# among them, on one worker. A program with no local task is placed
# there where preemption is built.
source "$ROOT/test/cli/_lib.sh"

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
  q = maker(20000000)&
  p = spinlocal(?n, 20000000)&
  print(>p + >q)
RIG

cat > starve.rig <<'RIG'
use std.task

obj Node
  v: Int

fun setter(n: ?*Node, c: *Cell[Int], k: Int) -> Int
  total = n.v
  for i in 0..k
    total = (total + i * 7) % 1000003
  !c.add(1)
  total

fun idle(n: ?*Node) -> Int
  n.v

fun waiter(c: *Cell[Int]) -> Int
  m = *Node(v: 2)
  t = idle(?m)&
  spins = 0
  while c.get() == 0
    spins += 1
  >t + spins % 1

sub main()
  task.workers(1)
  n = *Node(v: 1)
  c = *Cell(0)
  q = waiter(+c)&
  p = setter(?n, +c, 20000000)&
  print(>p > 0, >q)
RIG

cat > ring.rig <<'RIG'
use std.task

obj Node
  v: Int

fun stage(n: ?*Node, inc: *Cell[Int], out: *Cell[Int]) -> Int
  spins = 0
  while inc.get() == 0
    spins += 1
  !out.add(1)
  n.v + spins % 1

fun last(inc: *Cell[Int], out: *Cell[Int]) -> Int
  spins = 0
  while inc.get() == 0
    spins += 1
  !out.add(1)
  3 + spins % 1

sub main()
  task.workers(1)
  n = *Node(v: 1)
  c1 = *Cell(0)
  c2 = *Cell(0)
  c3 = *Cell(0)
  c4 = *Cell(0)
  c = last(+c3, +c4)&
  b = stage(?n, +c2, +c3)&
  a = stage(?n, +c1, +c2)&
  !c1.add(1)
  print(>a + >b + >c, c4.get())
RIG

cat > plain.rig <<'RIG'
use std.task

fun spin(k: Int) -> Int
  total = 0
  for i in 0..k
    total = (total + i * 3) % 1000003
  total

sub main()
  t = spin(1000)&
  print(>t)
RIG

for p in hold starve ring; do
    out=$("$TIMEOUT_CMD" 60 "$RIG" run --release $p.rig 2>err-$p.txt) || fail "$p.rig (timeout 60 s): $out $(cat err-$p.txt)"
    [ ! -s err-$p.txt ] || fail "$p.rig wrote to stderr: $(cat err-$p.txt)"
    "$RIG" emit $p.rig > $p.zig 2>&1 || fail "emit $p.rig: $(cat $p.zig)"
    ! grep -q "linksection(rig.preempt_section)" $p.zig || fail "$p.rig makes local tasks, but its functions are placed for preemption"
done
out=$("$RIG" run --release plain.rig 2>&1) || fail "plain.rig: $out"
expect_eq "$out" "498497" "plain.rig"
"$RIG" emit plain.rig > plain.zig 2>&1 || fail "emit plain.rig: $(cat plain.zig)"
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64 | Darwin/arm64)
        grep -q "linksection(rig.preempt_section)" plain.zig || fail "plain.rig makes no local task, but its functions are not placed for preemption" ;;
esac
