#!/usr/bin/env bash
# timeout: 300
# Where preemption by signal is built, a computation of any kind of code
# is stopped for a timer that comes due: on one worker, a task that
# sleeps 20 ms beside a task that computes for 70 to 300 ms wakes
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

cat > cover.rig <<'RIG'
use std.os
use std.par
use std.sort
use std.task
use std.text
use std.time

N = 20000000

fun sleeper() -> Int!
  t = time.now()
  time.sleep(ms: 20)!
  t.elapsed() / 1000000

fun cpu_closure() -> Int
  f = |n: Int|
    s = 0
    for i in 0..n
      s = (s + i * 7) % 1000003
    s
  f(N)

fun cpu_sort() -> Int
  xs: List[Int] = List(capacity: 600000)
  for i in 0..600000
    !xs.push((i *% 2654435761) % 1000003)
  sort.sort_by(!xs[..], |a, b|
    x = 0
    for k in 0..20
      x += (a + k) % 7
    a % 1000 + x * 0 < b % 1000
  )
  xs[0] + 1

fun cpu_map() -> Int
  m: Map[Int, Int] = Map()
  for i in 0..25000000
    !m.put(i % 500000, i)
  m.len

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

fun cpu_iter() -> Int
  it = Steps(n: 0, hi: N / 2)
  (!it).sum() + 1

obj Calc
  total: Int

  sub run(!@, n: Int)
    for i in 0..n
      @total = (@total + i * 7) % 1000003

  fun get(?@) -> Int
    @total

fun cpu_actor() -> Int
  a = *Actor(Calc(total: 0))
  !a.run(N)
  a.get() + 1

fun heavy(n: Int) -> Int
  s = 0
  for i in 0..n
    s = (s + i * 7) % 1000003
  s + 1

fun cpu_par() -> Int
  xs = [N / 4, N / 4, N / 4, N / 4]
  par.map(?xs, heavy).sum()

fun cpu_raw() -> Int
  s = 0
  raw
    for i in 0..N
      s = (s + i * 7) % 1000003
  s + 1

fun cpu_zig() -> Int
  s = String()
  for 0..4000000
    !s.push(97)
  w = 0
  for 0..20
    w += text.width(?s)
  w

fun cpu_divrem() -> Int
  s = 1
  for i in 1..N
    s = (s * 31 + i) % 1000003 + i / 7
  s

fun cpu_strcmp() -> Int
  a = String()
  b = String()
  for 0..200
    !a.push(97)
    !b.push(97)
  !b.push(98)
  n = 0
  for 0..N / 12
    if a == b
      n += 1
    if a < b
      n += 1
  n

fun cpu_hash() -> Int
  m: HashMap[String, Int] = HashMap()
  key = String()
  for 0..100
    !key.push(120)
  !m.put(String(key), 1)
  n = 0
  for 0..N / 2
    n += m.get(?key) ?? 0
  n

fun total(xs: ?[]Int) -> Int
  s = 0
  for x in xs
    s +%= x
  s

fun cpu_slice() -> Int
  xs: List[Int] = List(capacity: 4096)
  for i in 0..4096
    !xs.push(i)
  n = 0
  for k in 0..N / 100
    part = ?xs[k % 100..4000]
    n +%= total(?part)
  n

fun run(which: ?Static) -> Int
  return cpu_closure() if which == "closure"
  return cpu_sort() if which == "sort"
  return cpu_map() if which == "map"
  return cpu_iter() if which == "iter"
  return cpu_actor() if which == "actor"
  return cpu_par() if which == "par"
  return cpu_raw() if which == "raw"
  return cpu_zig() if which == "zig"
  return cpu_divrem() if which == "divrem"
  return cpu_strcmp() if which == "strcmp"
  return cpu_hash() if which == "hash"
  return cpu_slice() if which == "slice"
  0

sub main()!
  task.workers(1)
  which = os.args()[1]
  s = sleeper()&
  c = run(?which)&
  w = >s!
  print("woke", w, >c > 0)
RIG

# where BIN: the functions the signals a run of BIN declined found its
# fiber in (`RIG_SCHED_STATS=1`'s "declined at"), each with how
# test/cli/preempt_calls.txt reads it: named there, a function that stays
# outside the program's section for a reason, or a system library;
# otherwise unclassified, a function a signal cannot stop in that should
# be in the section.
where() {
    local name reading
    for a in $(grep -o 'declined at.*' err.txt | sed 's/declined at//' | tr ' ' '\n' | sort -u); do
        case $a in
            0x*) if [[ $(uname -s) == Darwin ]]; then name=$(atos -o "$1" "$a" 2>/dev/null | sed 's/ (in .*//'); else name=$(addr2line -f -e "$1" "$a" 2>/dev/null | head -1); fi ;;
            *) echo "$a (a system library)"; continue ;;
        esac
        name=${name#_}
        reading=unclassified
        while read -r pattern _; do
            [[ -z $pattern || $pattern == \#* ]] && continue
            [[ $name == $pattern ]] && { reading="named in preempt_calls.txt as $pattern"; break; }
        done < "$ROOT/test/cli/preempt_calls.txt"
        echo "$name ($reading)"
    done
}

# A run past 25 ms is run again, and fails only if it misses again, as
# the suite's load alone can delay a sleeper; the second run names where
# its declined signals were. PREEMPT_COVER_STRICT=1, the quiet gate
# before a release, takes no second run.
kinds="closure sort map iter actor par raw zig divrem strcmp hash slice"
"$RIG" build --release -o cover cover.rig >build.txt 2>&1 || fail "build cover.rig: $(cat build.txt)"
for k in $kinds; do
    for i in $(seq 1 20); do
        out=$("$TIMEOUT_CMD" 60 ./cover "$k" 2>&1) || fail "$k, run $i (timeout 60 s): $out"
        set -- $out
        [ "$1" = woke ] && [ "$3" = true ] || fail "$k, run $i: $out"
        [ "$2" -le 25 ] && continue
        first=$2
        [ "${PREEMPT_COVER_STRICT:-}" = 1 ] && fail "$k, run $i: the 20 ms sleeper woke after $first ms, beside a computation in $k"
        out=$(RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 ./cover "$k" 2>err.txt) || fail "$k, run $i again (timeout 60 s): $out"
        set -- $out
        [ "$2" -le 25 ] || fail "$k, run $i: the 20 ms sleeper woke after $first ms, and again after $2 ms, beside a computation in $k; its signals were declined in: $(where ./cover | tr '\n' ';')"
    done
done
exit 0
