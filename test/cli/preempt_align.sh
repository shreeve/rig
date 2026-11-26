#!/usr/bin/env bash
# timeout: 300
# A signal may stop a task where its stack pointer is not a multiple of
# eight: on x86-64, a function that calls none may move it by any count of
# bytes, as a debug build's `%` on a U32 does (`sub $20, %rsp` for its
# five 4-byte locals). The stop takes it, and the task resumes with its
# stack pointer exactly where it was: four tasks churning U32s on one
# worker, stopped every 200 µs, finish with the right sum, and the
# scheduler's counts show stops at an unaligned stack pointer. On arm64
# the stack pointer is always a multiple of 16 where code runs, and the
# same program runs clean.
source "$ROOT/test/cli/_lib.sh"
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64 | Darwin/arm64) ;;
    *) exit 0 ;;
esac

cat > align.rig <<'RIG'
use std.task

fun churn(seed: Int, k: Int) -> Int
  total: U32 = U32(seed)
  for i in 0..k
    total = (total *% 2654435761 +% U32(i % 65536)) % 256 +% total
  Int(total % 1000)

sub main()
  task.workers(1)
  a = churn(1, 3000000)&
  b = churn(2, 3000000)&
  c = churn(3, 3000000)&
  d = churn(4, 3000000)&
  print(>a + >b + >c + >d)
RIG

# The debug build: on x86-64 Linux, LLVM's (`-fllvm`), which preemption
# is built for, and whose leaf functions leave the stack pointer
# unaligned. One CPU, as cpuq gives a test case, where it can be had.
"$RIG" build -o align align.rig >build.txt 2>&1 || fail "build align.rig: $(cat build.txt)"
pin=env
if command -v taskset >/dev/null 2>&1; then pin="taskset -c $(taskset -pc $$ | sed 's/.*: //; s/[-,].*//')"; fi
want=$("$RIG" run --release align.rig 2>&1) || fail "align.rig, release: $want"
out=$(RIG_SCHED_STATS=1 RIG_PREEMPT_SLICE_US=200 "$TIMEOUT_CMD" 240 $pin ./align 2>err.txt) || fail "align.rig, debug, stopped every 200 µs: $out $(head -20 err.txt)"
expect_eq "$out" "$want" "align.rig, debug, stopped every 200 µs"
grep -q 'preempted [1-9]' err.txt || fail "align.rig: no task preempted: $(cat err.txt)"
if [[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]]; then
    grep -q '[1-9][0-9]* at an unaligned stack pointer' err.txt || fail "align.rig: no stop at an unaligned stack pointer, so the case no longer tests one: $(cat err.txt)"
fi
exit 0
