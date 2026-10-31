#!/bin/bash
# micro.sh ROUNDS: tabjit's arms on P-core 6 (sibling 7 idle); the stash arms' helper
# thread on E-core 12, or sharing core 6, rotated
# each round, at three levels in turn: natural (pup as it is), light (a
# fresh frag for each run takes every free 2 MiB block), quiet (unfrag 256
# first). Prints the free 2 MiB blocks before each run, then tabjit's line.
cd /zfs/worktrees/rig/table-huge/micro
R=${1:-10}
ARMS=("small 0" "whole 0" "gate 64" "jit 8" "collapse 8" "breaker 8" "stash 3 6,12" "stash4k 3 6,12" "stash 3 6" "stash4k 3 6")
free2m() { awk '$4!="DMA"{for(i=5;i<=NF;i++) if(i-5>=9) s+=$i*2^(i-5-9)} END{print s}' /proc/buddyinfo; }
quietcore() { while [ "$(ps -eo psr,pcpu --no-headers | awk '($1==6||$1==7)&&$2>5' | wc -l)" != 0 ]; do sleep 0.5; done; }
run() { # level arm F cpus
  if [ $1 = light ]; then
    coproc FR { exec taskset -c 12-19 ./frag 13312 2048; }
    while read -r l <&${FR[0]}; do case $l in ready*) break;; esac; done
  fi
  quietcore
  echo "level=$1 round=$r cpus=$4 free=$(free2m) $(taskset -c $4 ./tabjit $2 $3 $((r+1)))"
  if [ $1 = light ]; then kill $FR_PID; wait $FR_PID 2>/dev/null; sleep 2; fi
}
for level in natural light quiet; do
  [ $level = quiet ] && taskset -c 12-19 ./unfrag 256
  for r in $(seq 1 $R); do
    for k in $(seq 0 9); do
      a=(${ARMS[$(( (k + r) % 10 ))]})
      [ $level = quiet ] && taskset -c 12-19 ./unfrag 64 > /dev/null
      run $level ${a[0]} ${a[1]} ${a[2]:-6}
    done
  done
done
