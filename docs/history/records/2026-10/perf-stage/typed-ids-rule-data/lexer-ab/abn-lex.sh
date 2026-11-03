#!/bin/sh
# abn.sh N PROJECTS VARIANT...: interleave trig variants on core 3 (sibling
# 4 idle), check mode, one checker. A VARIANT is LABEL=COMMAND, a command
# such as "env BIN" or "env TRIG_LAZY_MEMBERS=1 BIN" (each runs through
# env, so all pay the same). PROJECTS is space-separated. Per project and
# variant: fastest task-clock, cycles and instructions (P-core, user), and
# median page faults and peak RSS, over N rounds. Every variant's stdout
# and exit status must agree with the first's.
set -u
n=$1; projects=$2; shift 2
out=$(mktemp -d /zfs/trig-cache/abn.XXXXXX)
ev=cpu_core/instructions/u,cpu_core/cycles/u,page-faults,task-clock
args="-p tsconfig.trig.json --noEmit --singleThreaded"
for p in $projects; do
  if [ $p = empty ]; then cd /zfs/trig-cache/fe-proj/empty; else cd "$HOME/Data/Code/trig/misc/projects/$p"; fi
  ok=1; k=0
  for v in "$@"; do
    k=$((k + 1)); cmd=${v#*=}
    e=0; taskset -c 3 $cmd $args >$out/v$k.out 2>&1 || e=$?
    echo $e >> $out/v$k.out
    if [ $k -gt 1 ] && ! cmp -s $out/v1.out $out/v$k.out; then echo "$p: ${v%%=*} differs from the first; not timed"; ok=0; fi
  done
  [ $ok = 1 ] || continue
  for i in $(seq 1 $n); do
    k=0
    for v in "$@"; do
      k=$((k + 1)); cmd=${v#*=}
      perf stat -x, -e $ev -o $out/v$k.$i.stat /usr/bin/time -f "%M %S" -o $out/v$k.$i.rss taskset -c 3 $cmd $args >/dev/null 2>&1 || true
    done
  done
  k=0
  for v in "$@"; do
    k=$((k + 1))
    t=$(grep -h ',task-clock,' $out/v$k.*.stat | cut -d, -f1 | sort -n | head -1)
    c=$(grep -h '/cycles/' $out/v$k.*.stat | cut -d, -f1 | sort -n | head -1)
    ins=$(grep -h '/instructions/' $out/v$k.*.stat | cut -d, -f1 | sort -n | head -1)
    f=$(grep -h ',page-faults,' $out/v$k.*.stat | cut -d, -f1 | sort -n | sed -n "$(( (n + 1) / 2 ))p")
    r=$(tail -qn1 $out/v$k.*.rss | cut -d" " -f1 | sort -n | sed -n "$(( (n + 1) / 2 ))p")
    printf '%-15s %-4s task-clock %8.1f ms  cycles %6.3fG  instr %6.3fG  faults %7d  rss %4d MB\n' "$p" "${v%%=*}" "$t" "$(echo "$c / 1000000000" | bc -l)" "$(echo "$ins / 1000000000" | bc -l)" "$f" "$((r / 1024))"
  done
  rm -f $out/*
done
rm -rf $out
