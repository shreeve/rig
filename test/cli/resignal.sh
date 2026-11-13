#!/usr/bin/env bash
# The monitor backs off a worker that keeps declining its signals: one
# blocked in a system call, here a write to stdout whose pipe is left
# full for a second while another task waits to run. Each signal there
# interrupts the write, which restarts, and does nothing else. Signalled
# every period, 50 µs, the worker took about 12,000 in that second; after
# four in a row each waits twice as long as the one before, up to 1 ms
# (`sched.resignalAfter`), so about 1,000. Where preemption is not built
# there are no signals, and this checks nothing.
source "$ROOT/test/cli/_lib.sh"

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64 | Darwin-arm64) ;;
    *) echo ok; exit 0 ;;
esac

cat > pipe.rig <<'RIG'
use std.task

fun writer() -> Int
  for i in 0..200000
    print(`line {i} of the writer, long enough to fill a pipe soon`)
  0

fun quick() -> Int
  1

sub main()
  task.workers(1)
  t = writer()&
  u = quick()&
  warn(>t + >u)
RIG

"$RIG" build --release -o pipe pipe.rig > build.txt 2>&1 || fail "build pipe.rig: $(cat build.txt)"
RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 ./pipe 2>err.txt | (sleep 1; cat > /dev/null)
grep -q '^1$' err.txt || fail "pipe.rig did not end with 1: $(cat err.txt)"
n=$(grep -o 'signaled [0-9]*' err.txt | head -1 | grep -o '[0-9]*')
[[ -n "$n" ]] || fail "no signal count: $(cat err.txt)"
(( n < 3000 )) || fail "a worker blocked a second writing to a full pipe took $n signals (under 3000 expected)"
echo ok
