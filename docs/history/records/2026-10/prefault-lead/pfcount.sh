#!/bin/sh
# pfcount.sh: MADV_POPULATE_WRITE calls (strace -f) in each bench of main and the change, on cores 6 and 7
P=/zfs/worktrees/rig/prefault-large
export PATH=$HOME/.local/go/bin:$PATH
n() { grep -c MADV_POPULATE_WRITE $1; }
for v in main fix; do
  for b in tasks actors net; do
    strace -f -qq -e trace=madvise -o /tmp/plc.st taskset -c 6,7 $P/b$b-$v/rig-fast > /dev/null 2>&1
    echo "$b $v: $(n /tmp/plc.st)"
  done
  strace -f -qq -e trace=madvise -o /tmp/plc.st taskset -c 6,7 $P/btasks-$v/rig-fast many > /dev/null 2>&1
  echo "tasks many $v: $(n /tmp/plc.st)"
  port=$((20000 + $$ % 1000))
  strace -f -qq -e trace=madvise -o /tmp/plc.st taskset -c 6,7 $P/bhttp-$v/rig-fast 127.0.0.1:$port > /dev/null 2>&1 &
  sleep 1
  taskset -c 6,7 $P/bhttp-$v/load -addr 127.0.0.1:$port -conns 64 -duration 2s > /dev/null
  pkill -f "rig-fast 127.0.0.1:$port"; sleep 0.5
  echo "http $v (64 conns, 2 s): $(n /tmp/plc.st)"
done
rm -f /tmp/plc.st
