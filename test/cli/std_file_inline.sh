# std.file's bounded calls (a stat, a directory's listing, a read of a
# regular file) run inline when their worker has nothing else to run,
# and on the blocking pool otherwise (docs/internals/scheduler.md, "The
# blocking pool"): RIG_SCHED_STATS=1 counts each. A FIFO is never read
# inline, so it never holds a worker, with and without seeds; a canceled
# task's call never starts; RIG_INLINE_FILE_CALLS=0 sends every call to
# the pool.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >idle.rig <<'EOF2'
use std.file

fun one() -> Int
  1

sub main()!
  t = one()&
  n = >t
  s = file.read("idle.rig")! ?? String()
  info = file.stat("idle.rig")!
  got = String()
  if file.open("idle.rig")! as f
    _ = (!f).read(!got, 8)!
  es = file.read_dir(".")! ?? List[file.Entry]()
  print(n, s.len > 0, info != none, got, es.len > 0, file.realpath(".")! != none, file.exists("idle.rig")!, file.read("nope")! == none)
EOF2

cat >busy.rig <<'EOF2'
use std.file

fun spin(n: Int) -> Int
  total = 0
  for i in 0..n
    total = (total + i * 7) % 1000003
  total

sub main()!
  t = spin(1000)&
  s = file.read("busy.rig")! ?? String()
  print(>t > 0, s.len > 0)
EOF2

# A FIFO's read waits for its writer, here the program itself: were it
# read inline, its one worker would never run the writer.
cat >pipe.rig <<'EOF2'
use std.file
use std.time

fun slow() -> Int!
  (file.read("fifo")! ?? String()).len

sub main()!
  r = slow()&
  time.sleep(20 * time.MS)!
  file.append("fifo", "x")!
  print(>r!)
EOF2

# Seeded, a blocking call runs in place on the one thread: the writer is
# outside.
cat >seeded.rig <<'EOF2'
use std.file

fun slow() -> Int!
  (file.read("fifo")! ?? String()).len

sub main()!
  r = slow()&
  print(>r!)
EOF2

cat >cancel.rig <<'EOF2'
use std.file
use std.time

fun napped() -> Bool
  time.sleep(time.SECOND) catch return false
  true

# Canceled as it naps: its stat fails before it starts.
fun first() -> Int!
  _ = napped()
  if file.stat("cancel.rig")! != none
    return 1
  0

sub main()!
  t = first()&
  time.sleep(5 * time.MS)!
  print(<t.cancel() catch |e| -2)
EOF2

for p in idle busy pipe seeded cancel; do
    rig build -o $p $p.rig >build.log 2>&1 || fail "build $p: $(cat build.log)"
done
calls() { grep '^rig: blocking calls' err.txt; }

RIG_SCHED_STATS=1 ./idle >out.txt 2>err.txt || fail "idle: exit $?: $(cat err.txt)"
expect_eq "$(cat out.txt)" "1 true true use std. true true true true" "idle's output"
expect_eq "$(calls)" "rig: blocking calls: inline 8, pool 0" "an idle worker's calls, inline"
RIG_INLINE_FILE_CALLS=0 RIG_SCHED_STATS=1 ./idle >out.txt 2>err.txt || fail "idle off: exit $?: $(cat err.txt)"
expect_eq "$(cat out.txt)" "1 true true use std. true true true true" "idle's output, inline calls off"
expect_eq "$(calls)" "rig: blocking calls: inline 0, pool 8" "RIG_INLINE_FILE_CALLS=0: every call on the pool"

RIG_WORKERS=1 RIG_SCHED_STATS=1 ./busy >out.txt 2>err.txt || fail "busy: exit $?: $(cat err.txt)"
expect_eq "$(cat out.txt)" "true true" "busy's output"
expect_eq "$(calls)" "rig: blocking calls: inline 0, pool 1" "a busy worker's call, on the pool"

for workers in 1 4; do
    rm -f fifo; mkfifo fifo
    out=$(RIG_WORKERS=$workers RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 20 ./pipe 2>err.txt); expect_rc $? 0 "fifo, $workers worker(s): $out $(cat err.txt)"
    expect_eq "$out" "1" "a FIFO read on the pool, $workers worker(s)"
    expect_eq "$(calls)" "rig: blocking calls: inline 0, pool 2" "a FIFO's read and write, on the pool"
done
for seed in $(seq 1 20); do
    rm -f fifo; mkfifo fifo
    (sleep 0.05; printf x >fifo) &
    out=$(RIG_SEED=$seed "$TIMEOUT_CMD" 20 ./seeded 2>&1); expect_rc $? 0 "seed $seed: $out"
    wait
    expect_eq "$out" "1" "a FIFO read, seed $seed"
done

RIG_SCHED_STATS=1 ./cancel >out.txt 2>err.txt || fail "cancel: exit $?: $(cat err.txt)"
expect_eq "$(cat out.txt)" "-2" "a canceled task's stat"
expect_eq "$(calls)" "rig: blocking calls: inline 0, pool 0" "a canceled task's call never starts"
exit 0
