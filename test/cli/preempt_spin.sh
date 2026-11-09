#!/usr/bin/env bash
# A task stopped by a signal, in a program with no local task: it hands
# over the only worker, and each stop fits the room it is given.
source "$ROOT/test/cli/_lib.sh"

cat > spin.rig <<'RIG'
use std.task

fun setter(c: *Cell[Int]) -> Int
  !c.add(1)
  1

fun waiter(c: *Cell[Int]) -> Int
  spins = 0
  while c.get() == 0
    spins += 1
  spins % 1

sub main()
  task.workers(1)
  c = *Cell(0)
  p = setter(+c)&
  q = waiter(+c)&
  print(>q, >p)
RIG

# A task that spins on the only worker, waiting for one queued behind it,
# with no local task: where preemption is built (Linux x86-64, arm64
# macOS), a signal stops it and the other runs, and the scheduler's
# counts show a task preempted; elsewhere the yield checks hand over.
on=$(RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 "$RIG" run --release=fast spin.rig 2>err-spin.txt) || fail "spin.rig (timeout 60 s): $on $(cat err-spin.txt)"
expect_eq "$on" "0 1" "spin.rig"
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64 | Darwin/arm64)
        grep -q 'preempted [1-9]' err-spin.txt || fail "spin.rig: no task preempted: $(cat err-spin.txt)" ;;
esac

# Each stop takes, from the stopped stack pointer to its switch to the
# worker's stack, no more of the fiber's stack than `sched.preempt_room`
# leaves above the guard: the trampoline's saves and the Zig frames
# before the switch fit, in fast and safe builds.
room() {
    awk -v what="$2" '/deepest stop/ { for (i = 1; i <= NF; i++) if ($i == "preempted") p = $(i + 1) + 0
        n = $(NF - 3) + 0; r = $(NF - 1) + 0
        if (p > 0 && (n == 0 || n > r)) { print what ": a stop took " n " of " r " bytes: " $0; bad = 1 }
        if (p > 0) seen = 1 }
        END { if (!seen) print what ": no stop measured"; exit bad || !seen }' "$1"
}
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64 | Darwin/arm64)
        msg=$(room err-spin.txt "spin.rig, fast") || fail "$msg"
        on=$(RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 "$RIG" run --release=safe spin.rig 2>err-spin-safe.txt) || fail "spin.rig, safe (timeout 60 s): $on $(cat err-spin-safe.txt)"
        msg=$(room err-spin-safe.txt "spin.rig, safe") || fail "$msg" ;;
esac
