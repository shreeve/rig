#!/bin/bash
cd "$(dirname "$0")"
for v in a b c; do
  for r in 1 2 3 4 5; do
    /usr/bin/time -l ./bench $v 100000000 2>&1 | awk '/instructions retired/{print $1}'
  done | sort -n | sed -n 3p | awk -v v=$v '{printf "%s median %.2f instr/iter\n", v, $1/1e8}'
done
