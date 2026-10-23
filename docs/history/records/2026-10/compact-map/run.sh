#!/bin/sh
# Interleaved, 7 rounds; print fastest build/get and RSS per binary.
for v in "$@"; do : > res_$v.txt; done
for r in 1 2 3 4 5 6 7; do
  for v in "$@"; do
    /usr/bin/time -l ./$v 2>&1 | awk '/build_ms/{b=$2; g=$4} /maximum resident/{m=$1} END{print b, g, m}' >> res_$v.txt
  done
done
for v in "$@"; do sort -n -k1 res_$v.txt | head -1 | awk -v v=$v '{b=$1}END{}{print v, "build", $1}'; sort -n -k2 res_$v.txt | head -1 | awk -v v=$v '{print v, "get", $2, "rss_mb", $3/1048576}'; done
