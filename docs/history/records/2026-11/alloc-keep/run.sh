#!/bin/bash
# run.sh ARM DENSE_K N: the run with the fewest kernel cycles of N: Rss KB, AnonHuge KB, faults, task-clock ms, kernel cycles M.
best=""
for i in $(seq $3); do
  out=$(taskset -c 12-19 perf stat -e page-faults,cycles:k,task-clock -x, ./drv-$1 $2 2>&1)
  rss=$(echo "$out" | awk "/^Rss:/{print \$2}"); huge=$(echo "$out" | awk "/^AnonHugePages:/{print \$2}")
  pf=$(echo "$out" | awk -F, "/page-faults/{print \$1}"); kc=$(echo "$out" | awk -F, "/cpu_atom\/cycles\/k/{printf \"%.1f\", \$1/1e6}")
  tc=$(echo "$out" | awk -F, "/task-clock/{printf \"%.2f\", \$1}")
  echo "$kc $tc $rss $huge $pf"
done | sort -n | head -1 | awk -v a=$1 -v d=$2 "{printf \"%-5s dense=%6sK  kcyc=%6sM  task=%6sms  rss=%7s  huge=%7s  faults=%5s\n\", a, d, \$1, \$2, \$3, \$4, \$5}"
