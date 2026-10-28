#!/bin/sh
# micro.sh N: collapse.c's four ways, 64 MiB each, quiet, fragmented
# (frag.c, a fresh one per run) and lightly fragmented (frag.c capped at
# 2 GiB), N rounds, each way in a process of its own, on core 1.
set -u
W=/zfs/worktrees/rig/thp-frag
N=${1:-5}
for r in $(seq 1 $N); do
  for mode in quiet frag light; do
    for way in fault collapse gated small; do
      F=
      case $mode in
        quiet) taskset -c 1 $W/unfrag 256 > /dev/null ;;
        frag) taskset -c 1 $W/frag 13312 1048576 > $W/micro.frag.out & F=$! ;;
        light) taskset -c 1 $W/frag 13312 2048 > $W/micro.frag.out & F=$! ;;
      esac
      if [ -n "$F" ]; then until grep -q '^ready' $W/micro.frag.out; do sleep 0.2; done; fi
      echo "round=$r mode=$mode $(taskset -c 1 $W/collapse 64 $way)"
      if [ -n "$F" ]; then kill $F; wait $F; sleep 2; fi
    done
  done
done
