#!/bin/sh
# rss.sh V...: each variant's peak anonymous and file-backed RSS on
# ts-pattern and zod3 (sampled every 5 ms while it runs, not once it is a zombie from /proc/PID/status, by a
# sampler on core 20; the checker on core 6), 3 runs each, the largest.
W=/zfs/worktrees/rig/runtime-unchecked
VS="$*"
for proj in ts-pattern zod3; do
  cd /zfs/worktrees/rig/check-bisect/projects/$proj
  for v in $VS; do
    best_a=0 best_f=0
    for r in 1 2 3; do
      taskset -c 6 $W/v/$v/bin -p tsconfig.trig.json --noEmit --singleThreaded > /dev/null 2>&1 &
      pid=$!
      out=$(taskset -c 20 sh -c "a=0; f=0; while [ \"\$(cut -d\" \" -f3 /proc/$pid/stat 2>/dev/null)\" = R ] || [ \"\$(cut -d\" \" -f3 /proc/$pid/stat 2>/dev/null)\" = S ] || [ \"\$(cut -d\" \" -f3 /proc/$pid/stat 2>/dev/null)\" = D ]; do set -- \$(awk '/^RssAnon/{a=\$2} /^RssFile/{f=\$2} END{print a+0, f+0}' /proc/$pid/status 2>/dev/null); [ \"\${1:-0}\" -gt \$a ] && a=\$1; [ \"\${2:-0}\" -gt \$f ] && f=\$2; sleep 0.005; done; echo \$a \$f")
      wait $pid
      a=${out% *} f=${out#* }
      [ $a -gt $best_a ] && best_a=$a; [ $f -gt $best_f ] && best_f=$f
    done
    echo "$proj $v anon_kb=$best_a file_kb=$best_f"
  done
done
