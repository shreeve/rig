#!/bin/bash
# casprobe3.sh add NAME BIN | del NAME: uprobes (group cas_NAME) on the instruction before each compare-and-swap onto a
# heap's remote list (any lock cmpxchg not on a %rip-relative lock word) in freeSlow, freeRecord*, Heap.freeSmall,
# Outgoing.flush, pushRemote and threadExit. Each is found in its function's own address range (nm -S) and placed by
# file offset through uprobe_events, so neither a shared name nor perf's debug-line lookup can move it.
set -u
G=cas_$2
case $1 in
del) sudo -n perf probe -q -d "$G:*" 2>/dev/null; exit 0 ;;
add)
  BIN=$(readlink -f "$3")
  sudo -n perf probe -q -d "$G:*" 2>/dev/null
  T=/sys/kernel/tracing/uprobe_events
  sudo -n test -e $T || T=/sys/kernel/debug/tracing/uprobe_events
  # The executable segment's address less its file offset.
  delta=$(readelf -lW "$BIN" | awk '$1 == "LOAD" && / R E / { print $3, $2 }' | { read v o; echo $(( v - o )); })
  nm -C -S --defined-only "$BIN" | grep -E ' [tT] rig\.alloc\.(freeSlow|freeRecord|Heap\.freeSmall|Outgoing\.flush|pushRemote|threadExit)' |
  while read addr size t sym; do
    stop=$(printf '0x%x' $(( 0x$addr + 0x$size )))
    objdump -d --no-show-raw-insn --start-address=0x$addr --stop-address=$stop "$BIN" |
      awk '/lock cmpxchg/ && !/\(%rip\)/ { print prev } { prev = $1; sub(/:.*/, "", prev) }' |
      while read next; do
        off=$(printf '0x%x' $(( 0x$next - delta )))
        echo "p:$G/c$next $BIN:$off" | sudo -n tee -a $T > /dev/null && echo "$sym 0x$next $off"
      done
  done
  sudo -n cat $T | grep -c "$G/" ;;
esac
