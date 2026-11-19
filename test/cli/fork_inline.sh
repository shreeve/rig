#!/usr/bin/env bash
# timeout: 300
# A fork its waiter takes back unstarted runs on the waiter's own stack
# and fiber (`sched.runHere`), when the room left there is at least what
# the fork's own stack would give it: on one worker a fork-join's forks
# all run so, but for those `main` waits for itself, whose stack is
# exactly 64 MiB, which hand off one a level. A chain whose levels each
# hold 256 KiB hands off once its waiter has used its stack's extra room
# (`rt.task_stack_extra`) and runs inline again below. A deterministic
# run (`RIG_SEED`) runs nothing inline. Counted by `RIG_SCHED_STATS=1`.
source "$ROOT/test/cli/_lib.sh"

cat > psum.rig <<'RIG'
use std.task

fun psum(xs: ?[]Int) -> Int
  return xs.sum() if xs.len <= 64
  mid = xs.len / 2
  right = xs[mid..]
  b = psum(?right)&
  a = psum(xs[..mid])
  a + >b

sub main()
  task.workers(1)
  xs: List[Int] = List()
  for i in 0..65536
    !xs.push(i)
  whole = ?xs[..]
  print(psum(whole))
RIG

cat > fat.rig <<'RIG'
use std.task

fun fat(n: Int) -> Int
  big: [32768]Int = [32768 of 1]
  big[100 + n] = n
  return 0 if n == 0
  t = fat(n - 1)&
  >t + big[100 + n] - n + big[1]

sub main()
  task.workers(1)
  w = fat(40)&
  print(>w)
RIG

# The sum of every worker's count `what` in the stats on stderr `err`.
count() { sed -n "s/.*[ ,]$1 \([0-9]*\).*/\1/p" "$2" | paste -sd+ - | bc; }

for mode in debug release; do
    flag=""; [[ $mode == release ]] && flag="--release"
    out=$(RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 "$RIG" run $flag psum.rig 2>err-psum.txt) || fail "psum $mode (timeout 60 s): $out $(cat err-psum.txt)"
    expect_eq "$out" "2147450880" "psum $mode"
    ran=$(count ran err-psum.txt); inlined=$(count inlined err-psum.txt)
    (( inlined >= 1000 )) || fail "psum $mode: $inlined of 1,023 forks ran inline: $(cat err-psum.txt)"
    (( ran <= 16 )) || fail "psum $mode: $ran fibers ran, past main's spine of 10: $(cat err-psum.txt)"

    out=$(RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 "$RIG" run $flag fat.rig 2>err-fat.txt) || fail "fat $mode (timeout 60 s): $out $(cat err-fat.txt)"
    expect_eq "$out" "40" "fat $mode"
    ran=$(count ran err-fat.txt); inlined=$(count inlined err-fat.txt)
    (( ran >= 6 && inlined >= 15 )) || fail "fat $mode: ran $ran, inlined $inlined: no handoff once the room ran short, or no inline run below it: $(cat err-fat.txt)"
done

out=$(RIG_SANITIZE=1 RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 "$RIG" run psum.rig 2>err-san.txt) || fail "psum sanitized (timeout 60 s): $out $(cat err-san.txt)"
expect_eq "$out" "2147450880" "psum sanitized"
(( $(count inlined err-san.txt) >= 1000 )) || fail "psum sanitized ran no fork inline: $(cat err-san.txt)"

out=$(RIG_SEED=7 RIG_SCHED_STATS=1 "$TIMEOUT_CMD" 60 "$RIG" run psum.rig 2>err-seed.txt) || fail "psum seeded (timeout 60 s): $out $(cat err-seed.txt)"
expect_eq "$out" "2147450880" "psum seeded"
inlined=$(count inlined err-seed.txt)
expect_eq "${inlined:-0}" "0" "a deterministic run runs no fork inline"
