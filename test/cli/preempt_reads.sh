#!/usr/bin/env bash
# Preemption by signal and code that spends its time outside the
# program's section, where a signal stops nothing: a signal left owed is
# paid at the task's next waiting point.
source "$ROOT/test/cli/_lib.sh"

# Tasks that loop on `file.read`, which reads a regular file in the task
# and spends its time in system calls, outside the program's code where
# a signal stops nothing, hand over their workers at each read's waiting
# point when a signal has asked them to (`sched.atWaitingPoint`): a task
# sleeping 20 ms beside eight of them on four workers wakes in time,
# where it waited for seconds in about half the runs.
printf 'some bytes to read\n' > small.txt
cat > reads.rig <<'RIG'
use std.file
use std.task
use std.time

fun reader(k: Int, stop: *Cell[Int]) -> Int!
  n = 0
  while stop.get() == 0
    s = file.read("small.txt")! ?? String()
    n += s.len
    time.sleep(ms: k % 2)!
  n

fun sleeper() -> Int!
  t = time.now()
  time.sleep(ms: 20)!
  t.elapsed() / 1000000

sub main()!
  task.workers(4)
  stop = *Cell(0)
  r0 = reader(0, +stop)&
  r1 = reader(1, +stop)&
  r2 = reader(2, +stop)&
  r3 = reader(3, +stop)&
  r4 = reader(4, +stop)&
  r5 = reader(5, +stop)&
  r6 = reader(6, +stop)&
  r7 = reader(7, +stop)&
  q = sleeper()&
  ms = >q!
  !stop.add(1)
  total = >r0! + >r1! + >r2! + >r3! + >r4! + >r5! + >r6! + >r7!
  print("woke", ms < 2000, total > 0)
RIG
"$RIG" build --release=fast -o reads reads.rig >build-reads.txt 2>&1 || fail "build reads.rig: $(cat build-reads.txt)"
for i in 1 2 3 4 5; do
    out=$("$TIMEOUT_CMD" 60 ./reads 2>&1) || fail "reads.rig run $i (timeout 60 s): $out"
    expect_eq "$out" "woke true true" "reads.rig run $i: the sleeper woke within 2 s"
done

# A loop that spends its time in std.text's searches, Zig code, is
# stopped by a signal there as in the program's own code: in a build
# preempted, the searches are in the program's code section
# (std/text.zig, `rig.preempt_section`). A task sleeping 20 ms beside two
# such loops on one worker wakes in time, where it woke in 30 ms to
# 15.8 s (docs/history/records/2026-11/preempt/default-on-2026-11-06.md).
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64 | Darwin/arm64)
        cat > finds.rig <<'RIG'
use std.task
use std.text
use std.time

fun searcher(k: Int, stop: *Cell[Int]) -> Int!
  n = 0
  big = String()
  for i in 0..200000
    !big.push(U8(0x61 + (i * 7 + k) % 23))
  while stop.get() == 0
    n += text.find(big, "zzzq") ?? 1
  n

fun sleeper() -> Int!
  t = time.now()
  time.sleep(ms: 20)!
  t.elapsed() / 1000000

sub main()!
  task.workers(1)
  stop = *Cell(0)
  s0 = searcher(0, +stop)&
  s1 = searcher(1, +stop)&
  q = sleeper()&
  ms = >q!
  !stop.add(1)
  total = >s0! + >s1!
  print(ms, total > 0)
RIG
        "$RIG" build --release=fast -o finds finds.rig >build-finds.txt 2>&1 || fail "build finds.rig: $(cat build-finds.txt)"
        for i in 1 2 3 4 5; do
            out=$("$TIMEOUT_CMD" 60 ./finds 2>&1) || fail "finds.rig run $i (timeout 60 s): $out"
            [[ ${out#* } == true ]] || fail "finds.rig run $i: $out"
            (( ${out%% *} <= 100 )) || fail "finds.rig run $i: the sleeper woke after ${out%% *} ms, past 100 ms"
        done ;;
esac
