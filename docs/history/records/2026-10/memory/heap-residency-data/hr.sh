#!/bin/sh
# hr.sh: the heap report on pup's E-cores; cores, workers (- for default), checkers
B=/zfs/worktrees/rig/heap-report/trig-main
for p in zod3 mitt ts-pattern; do
  cd /zfs/trig-pup/full/trig/misc/projects/$p
  for mode in "12-15 -" "12-19 -" "12-19 22"; do
    set -- $mode
    for c in 4 1; do
      [ $p = ts-pattern ] && [ $c = 1 ] && [ "$1" != 12-15 ] && continue
      if [ "$2" = - ]; then w=""; else w="RIG_WORKERS=$2"; fi
      out=$(env $w taskset -c $1 /usr/bin/time -v $B -p tsconfig.trig.json --noEmit --checkers $c 2>&1 >/dev/null)
      rss=$(echo "$out" | awk '/Maximum resident/{printf "%.1f", $6/1024}')
      heaps=$(echo "$out" | grep -c '^@@heap  *[0-9]')
      all=$(echo "$out" | grep '^@@heap all' | sed 's/@@heap all *//')
      echo "$p cores=$1 workers=$2 checkers=$c heaps=$heaps rss=$rss | $all"
    done
  done
done
