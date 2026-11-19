#!/bin/bash
# rss.sh: peak RSS (KB, /usr/bin/time %M) of main against the branch, on E-cores 12-19 only, while
# no slot is open; 5 interleaved runs each. fork at RIG_WORKERS 1 and 8; bench/tasks' timed run, and
# its `many` and `idle` runs (bench-tasks' memory row is their difference over 10,000 tasks).
D=/zfs/trig-pup/psum-gap/mem/b4
free_slot() { for i in $(seq 360); do /zfs/trig-pup/bin/pup-slot state | grep -q "slot=none" && return 0; sleep 10; done; exit 1; }
for k in 1 2 3 4 5; do
  for a in main new; do
    free_slot
    for w in 1 8; do echo "fork-w$w $a $(RIG_WORKERS=$w taskset -c 12-19 /usr/bin/time -f %M $D/fork-$a 2>&1 >/dev/null)"; done
    echo "tasks $a $(RIG_WORKERS=8 taskset -c 12-19 /usr/bin/time -f %M $D/tasks-$a 2>&1 >/dev/null)"
    echo "tasks-many $a $(RIG_WORKERS=8 taskset -c 12-19 /usr/bin/time -f %M $D/tasks-$a many 2>&1 >/dev/null)"
    echo "tasks-idle $a $(RIG_WORKERS=8 taskset -c 12-19 /usr/bin/time -f %M $D/tasks-$a idle 2>&1 >/dev/null)"
  done
done
