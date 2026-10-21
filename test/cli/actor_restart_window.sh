# A supervised actor counts its restarts within `per:` nanoseconds: one
# after the window is allowed again, a second within it is not; and a
# call queued while the actor dies waits for the new value. The window
# is a span of the clock, and between the deaths it counts a panic
# report is written, which takes a worker that has written none before
# tens of milliseconds on a busy machine, so the case runs only under
# seeds (RIG_SEED, as `rig test` sets), whose virtual clock makes the
# window exact (docs/internals/scheduler.md, "Deterministic runs").
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >restarts.rig <<'EOF'
use std.task
use std.time

obj Slow
  n: Int

  fun hold(!@) -> Int!
    @n += 5
    time.sleep(20 * time.MS)!
    @n

  fun boom(?@, i: Int) -> Int
    [1, 2, 3][i]

  fun get(?@) -> Int
    @n

fun holder(a: *Actor[Slow]) -> Int!
  (!a).hold()!

fun behind(a: *Actor[Slow]) -> Int!
  time.sleep(2 * time.MS)!
  a.get()

sub main()!
  made = *Cell(0)
  a = *Actor.supervised(*|+made| Slow(n: 100 * (!made).add(1)), restarts: 1, per: 10 * time.MS)
  t = holder(+a)&
  time.sleep(5 * time.MS)!
  u = behind(+a)&
  n = task.isolate(|+a| a.boom(9)) catch -1
  print(n, >t!, >u!)
  time.sleep(20 * time.MS)!
  _ = task.isolate(|+a| a.boom(9)) catch -1
  print(a.get(), made.get())
  _ = task.isolate(|+a| a.boom(9)) catch -1
  print(task.isolate(|+a| a.get()) catch -2)
EOF
rig build -o restarts restarts.rig >build.log 2>&1 || fail "build restarts: $(cat build.log)"
want=$'-1 105 200\n300 3\n-2'
for seed in $(seq 1 20); do
    out=$(RIG_SEED=$seed ./restarts 2>/dev/null) || fail "seed $seed: exit $?"
    expect_eq "$out" "$want" "seed $seed"
done
exit 0
