#!/bin/sh
# polite.sh: run each job line of $W/jobs in turn; before each, wait until
# no other job's release-slot is still waiting for a slot (sleeping), or
# 2 minutes when none was waiting.
W=/zfs/worktrees/rig/trig-zig-ceiling
cd $W
waiting_others() {
  for p in $(pgrep -f "release-slot"); do
    grep -q trig-zig-ceiling /proc/$p/cmdline 2>/dev/null && continue
    pgrep -P $p -x sleep > /dev/null && return 0
  done
  return 1
}
while read -r job; do
  [ -z "$job" ] && continue
  if waiting_others; then
    while waiting_others; do sleep 15; done
    sleep 20
  else
    sleep 120
  fi
  echo "# $(date +%T) start: $job"
  sh -c "$job"
done < $W/jobs
