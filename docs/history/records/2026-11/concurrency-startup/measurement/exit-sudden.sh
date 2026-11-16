#!/bin/bash
# exit-sudden.sh EXE: ten runs each at 8 and 10 workers of a release build
# of test/cli/exit_teardown.sh's `sudden` program (its `parked` without
# the 5 ms sleep: os.exit at once after the first tasks), and the path
# each exit took: T torn down, STUCK "plain, the workers did not stop",
# task "plain, a task runs".
err=$(mktemp)
for w in 8 10; do
    line=""
    for i in $(seq 1 10); do
        RIG_SCHED_STATS=1 RIG_WORKERS=$w "$1" >/dev/null 2>"$err"
        e=$(grep '^rig: exit:' "$err")
        case "$e" in
        *"torn down"*) line="$line T" ;;
        *"did not stop"*) line="$line STUCK" ;;
        *"a task runs"*) line="$line task" ;;
        *) line="$line ?($e)" ;;
        esac
    done
    echo "w=$w:$line"
done
rm -f "$err"
