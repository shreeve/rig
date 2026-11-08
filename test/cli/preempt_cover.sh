#!/usr/bin/env bash
# Where preemption by signal is built, a computation of any kind of code
# is stopped for a timer that comes due: on one worker, a task that
# sleeps 20 ms beside a task that computes for 130 to 500 ms wakes
# within 25 ms, in 20 runs of 20. The computation runs in a closure, a
# sort's comparator, a Map's hashing (the runtime's Zig), an iterator's
# `next`, an actor's method, a `par` element function, a `raw` block, a
# std function written in Zig (`text.width`), and the runtime's helpers
# the program's code calls: `%` and `/`, a comparison of text, a
# HashMap's hash of a long key, and a slice passed to a function. The
# program's section, where a signal stops a task, holds them, or calls
# out only to what test/cli/preempt_calls.txt names
# (test/cli/preempt_section.sh). Where preemption is not built, nothing
# runs.
source "$ROOT/test/cli/_lib.sh"
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64 | Darwin/arm64) ;;
    *) exit 0 ;;
esac

cat > head.rig <<'RIG'
use std.task
use std.time

N = 60000000

fun sleeper() -> Int!
  t = time.now()
  time.sleep(ms: 20)!
  t.elapsed() / 1000000

RIG

cat > tail.rig <<'RIG'

sub main()!
  task.workers(1)
  s = sleeper()&
  c = cpu()&
  w = >s!
  print("woke", w, >c > 0)
RIG

cat > k-closure.rig <<'RIG'
fun cpu() -> Int
  f = |n: Int|
    s = 0
    for i in 0..n
      s = (s + i * 7) % 1000003
    s
  f(N)
RIG

cat > k-sort.rig <<'RIG'
use std.sort

fun cpu() -> Int
  xs: List[Int] = List(capacity: 1500000)
  for i in 0..1500000
    !xs.push((i *% 2654435761) % 1000003)
  sort.sort_by(!xs[..], |a, b|
    x = 0
    for k in 0..20
      x += (a + k) % 7
    a % 1000 + x * 0 < b % 1000
  )
  xs[0] + 1
RIG

cat > k-map.rig <<'RIG'
fun cpu() -> Int
  m: Map[Int, Int] = Map()
  for i in 0..30000000
    !m.put(i % 500000, i)
  m.len
RIG

cat > k-iter.rig <<'RIG'
obj Steps
  n: Int
  hi: Int

  fun next(!@) -> Int?
    return none if @n >= @hi
    @n += 1
    x = @n
    for k in 0..8
      x = (x * 31 + k) % 1000003
    x

fun cpu() -> Int
  it = Steps(n: 0, hi: N / 2)
  (!it).sum() + 1
RIG

cat > k-actor.rig <<'RIG'
obj Calc
  total: Int

  sub run(!@, n: Int)
    for i in 0..n
      @total = (@total + i * 7) % 1000003

  fun get(?@) -> Int
    @total

fun cpu() -> Int
  a = *Actor(Calc(total: 0))
  !a.run(N)
  a.get() + 1
RIG

cat > k-par.rig <<'RIG'
use std.par

fun heavy(n: Int) -> Int
  s = 0
  for i in 0..n
    s = (s + i * 7) % 1000003
  s + 1

fun cpu() -> Int
  xs = [N / 4, N / 4, N / 4, N / 4]
  par.map(?xs, heavy).sum()
RIG

cat > k-raw.rig <<'RIG'
fun cpu() -> Int
  s = 0
  raw
    for i in 0..N
      s = (s + i * 7) % 1000003
  s + 1
RIG

cat > k-zig.rig <<'RIG'
use std.text

fun cpu() -> Int
  s = String()
  for 0..4000000
    !s.push(97)
  w = 0
  for 0..60
    w += text.width(?s)
  w
RIG

cat > k-divrem.rig <<'RIG'
fun cpu() -> Int
  s = 1
  for i in 1..N
    s = (s * 31 + i) % 1000003 + i / 7
  s
RIG

cat > k-strcmp.rig <<'RIG'
fun cpu() -> Int
  a = String()
  b = String()
  for 0..200
    !a.push(97)
    !b.push(97)
  !b.push(98)
  n = 0
  for 0..N / 40
    if a == b
      n += 1
    if a < b
      n += 1
  n
RIG

cat > k-hash.rig <<'RIG'
fun cpu() -> Int
  m: HashMap[String, Int] = HashMap()
  key = String()
  for 0..100
    !key.push(120)
  !m.put(String(key), 1)
  n = 0
  for 0..N / 20
    n += m.get(?key) ?? 0
  n
RIG

cat > k-slice.rig <<'RIG'
fun total(xs: ?[]Int) -> Int
  s = 0
  for x in xs
    s +%= x
  s

fun cpu() -> Int
  xs: List[Int] = List(capacity: 4096)
  for i in 0..4096
    !xs.push(i)
  n = 0
  for k in 0..N / 1500
    part = ?xs[k % 100..4000]
    n +%= total(?part)
  n
RIG

for k in closure sort map iter actor par raw zig divrem strcmp hash slice; do
    cat head.rig "k-$k.rig" tail.rig > "$k.rig"
    "$RIG" build --release=fast -o "$k" "$k.rig" >build.txt 2>&1 || fail "build $k.rig: $(cat build.txt)"
    for i in $(seq 1 20); do
        out=$("$TIMEOUT_CMD" 60 "./$k" 2>&1) || fail "$k.rig, run $i (timeout 60 s): $out"
        set -- $out
        [ "$1" = woke ] && [ "$3" = true ] || fail "$k.rig, run $i: $out"
        [ "$2" -le 25 ] || fail "$k.rig, run $i: the 20 ms sleeper woke after $2 ms, beside a computation in $k"
    done
done
exit 0
