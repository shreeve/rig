#!/bin/bash
# timeit.sh N BIN...: interleaved runs at n=21; prints each run's wall, user+sys, peak RSS.
cd ~/Data/Code/Claude/rig/rig/bt200-panel/probes-compiler
N=$1; shift
for b in "$@"; do ./$b 21 | md5 | sed "s/^/$b md5 /"; done
for i in $(seq $N); do
  for b in "$@"; do
    /usr/bin/time -l ./$b 21 2>tmp.time >/dev/null
    awk -v b=$b '/real/ {w=$1; u=$3; s=$5} /maximum resident/ {m=$1} END {printf "%s wall %.3f cpu %.2f rss %d MB\n", b, w, u+s, m/1048576}' tmp.time
  done
done
