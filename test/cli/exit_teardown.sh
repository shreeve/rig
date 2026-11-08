# On the Mac a release build's `os.exit` first stops the other workers
# and unmaps the program's Tables, segments and free fiber stacks on all
# of them, when every other worker can be stopped (`sched.tearDown`;
# docs/history/records/2026-11/exit/parallel-teardown.md). With
# RIG_SCHED_STATS=1 it says which path it took. Elsewhere, and in a
# debug build, `os.exit` ends the process as before, and says nothing.
# builds: shared
# timeout: 240
source "$ROOT/test/cli/_lib.sh"

# Tables of 24 MiB: on 4 workers their regions' pieces are 96 MiB, a
# multiple of a page table's 32 MiB but no power of two.
cat >parked.rig <<'EOF'
use std.os
use std.time

obj Big
  t: Table[Int, 3000000]

fun nap(ms: Int) -> Int!
  xs: List[Int] = List()
  time.sleep(ms: ms)!
  for i in 0..1000
    !xs.push(i)
  xs.len

sub main()!
  keep: List[Big] = List()
  for i in 0..64
    b = Big(t: Table())
    !b.t.push(i)
    !keep.push(<b)
  ts = Tasks[Int!]()
  for i in 0..16
    !ts.add(nap(100000 + i)&)
  time.sleep(ms: 5)!
  print("exiting", keep.len)
  os.exit(4)
  _ = >ts!
EOF

# A task that never waits keeps its worker from stopping.
cat >running.rig <<'EOF'
use std.os
use std.time

obj Big
  t: Table[Int, 4000000]

sub spin()
  n = 0
  while n >= 0
    n = (n + 1) % 1000

sub main()!
  keep: List[Big] = List()
  for i in 0..64
    b = Big(t: Table())
    !b.t.push(i)
    !keep.push(<b)
  a = spin()&
  time.sleep(ms: 5)!
  print("exiting", keep.len)
  os.exit(6)
EOF

# Little to free: waking the workers would cost more than it saves.
cat >small.rig <<'EOF'
use std.os
use std.time

fun nap(ms: Int) -> Int!
  time.sleep(ms: ms)!
  ms

sub main()!
  ts = Tasks[Int!]()
  for i in 0..4
    !ts.add(nap(100000 + i)&)
  time.sleep(ms: 5)!
  print("exiting")
  os.exit(3)
  _ = >ts!
EOF

mac=0; [[ $(uname) == Darwin ]] && mac=1
for mode in "" --release --release=fast; do
    for prog in parked running small; do
        rig build $mode -o $prog $prog.rig >build.log 2>&1 || fail "build $prog $mode: $(cat build.log)"
    done
    for round in 1 2 3; do
        RIG_SCHED_STATS=1 RIG_WORKERS=4 ./parked >out.txt 2>err.txt; expect_rc $? 4 "parked $mode"
        expect_eq "$(cat out.txt)" "exiting 64" "parked's output $mode"
        exits=$(grep '^rig: exit:' err.txt)
        if [[ -n $mode && $mac == 1 ]]; then
            expect_has "$exits" "rig: exit: torn down on 4 of 4 workers" "parked tears down $mode"
        else
            expect_eq "$exits" "" "parked: no teardown $mode"
        fi
        RIG_SCHED_STATS=1 RIG_WORKERS=4 ./running >out.txt 2>err.txt; expect_rc $? 6 "running $mode"
        expect_eq "$(cat out.txt)" "exiting 64" "running's output $mode"
        exits=$(grep '^rig: exit:' err.txt)
        if [[ -n $mode && $mac == 1 ]]; then
            expect_eq "$exits" "rig: exit: plain, a task runs" "running ends plainly $mode"
        else
            expect_eq "$exits" "" "running: no teardown $mode"
        fi
        RIG_SCHED_STATS=1 RIG_WORKERS=4 ./small >out.txt 2>err.txt; expect_rc $? 3 "small $mode"
        exits=$(grep '^rig: exit:' err.txt)
        if [[ -n $mode && $mac == 1 ]]; then
            expect_eq "$exits" "rig: exit: plain, little to free" "small ends plainly $mode"
        fi
    done
done

# One worker: nothing to stop, nothing to help.
rig build --release -o parked parked.rig >build.log 2>&1 || fail "build parked: $(cat build.log)"
RIG_SCHED_STATS=1 RIG_WORKERS=1 ./parked >out.txt 2>err.txt; expect_rc $? 4 "parked on one worker"
if [[ $mac == 1 ]]; then
    expect_eq "$(grep '^rig: exit:' err.txt)" "rig: exit: plain, one worker" "one worker ends plainly"
fi

# Preempted by signal, the stopped workers and the exiting task are never
# stopped by one mid-teardown.
RIG_PREEMPT=signal rig build --release -o parked_pre parked.rig >build.log 2>&1 || fail "build parked_pre: $(cat build.log)"
for round in 1 2 3; do
    RIG_SCHED_STATS=1 RIG_WORKERS=4 ./parked_pre >out.txt 2>err.txt; expect_rc $? 4 "parked, preempted"
    expect_eq "$(cat out.txt)" "exiting 64" "parked's output, preempted"
    if [[ $mac == 1 ]]; then
        expect_has "$(grep '^rig: exit:' err.txt)" "rig: exit: torn down on 4 of 4 workers" "preempted parked tears down"
    fi
done
exit 0
