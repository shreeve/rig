#!/usr/bin/env bash
# timeout: 180
# A panic in an actor's method while tasks it started run on dense stacks
# (#1044's cases). The suite's own builds seal no guard into their
# executables, so they run every task on a large stack: these are release
# builds, whose guard is sealed (`sealDenseGuard`). A dense stack is reused
# without being unmapped, so a late reader of one would see another task's
# data and not fault. A build that sanitizes retires each finished stack
# (`retireDense`), where that read does fault.
source "$ROOT/test/cli/_lib.sh"

check() { # NAME EXPECTED
    local name=$1 want=$2 out run
    "$RIG" emit "$name.rig" 2>&1 | grep -q 'spawnDense(' || fail "$name: no task is on a dense stack"
    "$RIG" build --release -o "$name" "$name.rig" >build.txt 2>&1 || fail "build $name: $(cat build.txt)"
    python3 - "$name" <<'PY' || fail "$name: no guard was written into the executable"
import sys
d = open(sys.argv[1], "rb").read()
i = d.find(b"rig-dense-guard!")
sys.exit(0 if i >= 0 and int.from_bytes(d[i + 16:i + 24], "little") > 0 else 1)
PY
    RIG_SANITIZE=1 "$RIG" build --release -o "$name-s" "$name.rig" >build-s.txt 2>&1 || fail "build sanitized $name: $(cat build-s.txt)"
    for run in 1 2 3 4 5; do
        out=$("$TIMEOUT_CMD" 30 "./$name" 2>err.txt | tr '\n' '/') || fail "$name run $run: $(tail -3 err.txt)"
        expect_eq "$out" "$want/" "$name run $run"
        out=$(RIG_SANITIZE=1 "$TIMEOUT_CMD" 30 "./$name-s" 2>err.txt | tr '\n' '/') || fail "sanitized $name run $run: $(tail -3 err.txt)"
        expect_eq "$out" "$want/" "sanitized $name run $run"
    done
}

cat > stops.rig <<'RIG'
use std.task
use std.time

sub nap(ms: Int)
  time.sleep(ms: ms) catch |_|
    return

sub reader(s: ?[8]Int)
  nap(20)
  print(s[0], s[7])

obj S
  n: Int

  sub slow(!@)
    nap(20)

  fun work(!@) -> Int
    local = [8 of @n + 41]
    t = reader(?local)&
    panic("mid") if @n > 0
    >t
    1

sub first(a: *Actor[S])
  !a.slow()

fun second(a: *Actor[S]) -> Int
  !a.work()


sub main()
  # The method's stack goes when the panic ends the runner, so the task
  # lent a local on it must have ended first: it reads the local after
  # its sleep is canceled, and before the caller learns of the panic.
  a = *Actor(S(n: 1))
  t = first(+a)&
  time.sleep(ms: 5)!
  u = task.isolate(|+a| second(+a)) catch |e|
    print("caught", e)
    -1
  >t
  print(u)
RIG
check stops '42 42/caught Stop.panicked/-1'

cat > answers.rig <<'RIG'
use std.task
use std.time

sub nap(ms: Int)
  time.sleep(ms: ms) catch |_|
    return

sub reader(s: ?[8]Int)
  nap(20)
  print(s[0], s[7])

obj S
  n: Int

  sub slow(!@)
    nap(20)

  fun work(?@, v: ?[8]Int) -> Int
    t = reader(v)&
    panic("mid") if @n > 0
    >t
    1

sub first(a: *Actor[S])
  !a.slow()

fun second(a: *Actor[S]) -> Int
  local = [8 of 7]
  a.work(?local)


sub main()
  # A task the method started may view its caller's frames too, so the
  # caller goes on only once the task has ended.
  a = *Actor(S(n: 1))
  t = first(+a)&
  time.sleep(ms: 5)!
  u = task.isolate(|+a| second(+a)) catch |e|
    print("caught", e)
    -1
  >t
  print(u)
RIG
check answers '7 7/caught Stop.panicked/-1'

cat > ends.rig <<'RIG'
use std.task
use std.time

sub nap(ms: Int)
  time.sleep(ms: ms) catch |_|
    return

sub boom()
  panic("in the task")

obj S
  n: Int

  sub slow(!@)
    nap(20)

  fun work(?@) -> Int
    t = boom()&
    >t
    @n

  fun get(?@) -> Int
    @n

sub first(a: *Actor[S])
  !a.slow()


sub main()
  # The task's panic passes to the method that waits for it, and the
  # actor's own task is the boundary it stops at.
  a = *Actor(S(n: 1))
  t = first(+a)&
  time.sleep(ms: 5)!
  u = task.isolate(|+a| a.work()) catch |e|
    print("caught", e)
    -1
  print(u)
  >t
  v = task.isolate(|+a| a.get()) catch |e|
    print("caught again", e)
    -2
  print(v)
RIG
check ends 'caught Stop.panicked/-1/caught again Stop.panicked/-2'

cat > restarts.rig <<'RIG'
use std.task
use std.time

sub nap(ms: Int)
  time.sleep(ms: ms) catch |_|
    return

sub reader(s: ?Int)
  nap(20)
  print("read", s)

obj S
  n: Int

  sub slow(!@)
    nap(20)

  fun work(?@) -> Int
    t = reader(?@n)&
    panic("mid") if @n > 0
    >t
    1

  fun get(?@) -> Int
    @n

fun mk() -> S
  print("made")
  S(n: 5)

sub first(a: *Actor[S])
  !a.slow()

fun later(a: *Actor[S]) -> Int
  nap(5)
  a.get()


sub main()
  # The task views the value the panic abandoned, in the place the new
  # value is made, so the value is made again only once the task has
  # ended.
  a = *Actor.supervised(*|| mk())
  t = first(+a)&
  time.sleep(ms: 5)!
  v = later(+a)&
  time.sleep(ms: 2)!
  u = task.isolate(|+a| a.work()) catch -1
  >t
  print(u, >v)
RIG
check restarts 'made/read 5/made/-1 5'

echo ok
