#!/bin/sh
# ab.sh CONFIG N PROJECTS...: each arm of CONFIG once a round, in an order
# shuffled by the round (seeded), after a warm-up run, under
# `taskset -c CORES perf stat --no-scale` (perf pinned with the program).
# CONFIG sets V (arms), EV (perf events), O (output dir), and cmd_of ARM
# (prints "CORES BINARY ARGS..."). Binaries run from /tmp (tmpfs).
# PRE, if set, runs before each run (unfrag, for the quiet level).
# Waits out Trig's full suite and its cron hours (00, 04, ... 20).
# Each line: PROJ round= v= <perf fields> rss_kb= minflt= free2m= gate=
# thp= cstall= exit= same= load=
#   free2m: free 2 MiB blocks outside DMA (/proc/buddyinfo) at the start;
#   gate: 1 when above 64 (a Table's `hugeFree`), else 0;
#   thp, cstall: change in thp_fault_alloc and compact_stall over the run
#   (the whole machine's).
set -u
CONFIG=$(readlink -f "$1"); N=$2; shift 2
. "$CONFIG"
mkdir -p $O
PR=/zfs/trig-pup/full/trig/misc/projects
free2m() { awk '$4 != "DMA" { b = 0; for (i = 14; i <= NF; i++) b += $i * 2 ^ (i - 14); s += b } END { print s }' /proc/buddyinfo; }
vm() { awk -v k=$1 '$1 == k { print $2 }' /proc/vmstat; }
quiet() {
  while :; do
    h=$(date +%-H); m=$(date +%-M)
    if pgrep -f "tools/full-main" > /dev/null; then echo "# $(date +%T) waiting: Trig's suite"; sleep 60; continue; fi
    if [ $((h % 4)) -eq 3 -a $m -ge 57 ] || [ $((h % 4)) -eq 0 -a $m -lt 12 ]; then echo "# $(date +%T) waiting: cron hour"; sleep 60; continue; fi
    break
  done
}
run() { # run PROJ ARM
  set -- $1 $2 $(cmd_of $2); proj=$1 arm=$2 cores=$3; shift 3
  [ -n "${PRE:-}" ] && sh -c "$PRE" > /dev/null 2>&1
  e=0; f2=$(free2m); t0=$(vm thp_fault_alloc); c0=$(vm compact_stall)
  /usr/bin/time -f "%M %R" -o $O/time taskset -c $cores perf stat --no-scale -x, -e $EV -o $O/perf "$@" > $O/out.$proj.$arm 2>&1 || e=$?
  t1=$(vm thp_fault_alloc); c1=$(vm compact_stall)
  f=$(awk -F, '/^[0-9]/ { k=$3; sub("cpu_atom/", "", k); sub("cpu_core/", "", k); sub("/$", "", k); gsub("/", "", k); printf "%s=%s ", k, $1 }' $O/perf)
  set -- $(tail -n 1 $O/time)
  g=0; [ $f2 -gt 64 ] && g=1
  echo "${f}rss_kb=$1 minflt=$2 free2m=$f2 gate=$g thp=$((t1 - t0)) cstall=$((c1 - c0)) exit=$e"
}
order() { echo $V | tr ' ' '\n' | awk -v seed=$1 'BEGIN { srand(seed) } { print rand(), $0 }' | sort -n | cut -d' ' -f2 | tr '\n' ' '; }
FIRST=${V%% *}
echo "# start $(date +%T) N=$N load $(cut -d' ' -f1-3 /proc/loadavg)"
for proj in "$@"; do
  if [ $proj = empty ]; then cd /tmp/kl/empty; else cd $PR/$proj; fi
  quiet
  for v in $V; do run $proj $v > /dev/null; cp $O/out.$proj.$v $O/ref.$proj.$v; done
  for v in $V; do cmp -s $O/ref.$proj.$v $O/ref.$proj.$FIRST && echo "# $proj: $v same as $FIRST" || echo "# $proj: $v DIFFERS from $FIRST"; done
  r=1
  while [ $r -le $N ]; do
    quiet
    [ -n "${WARM:-}" ] && run $proj $WARM > /dev/null
    for v in $(order $r); do
      line=$(run $proj $v)
      same=1; cmp -s $O/ref.$proj.$FIRST $O/out.$proj.$v || same=0
      echo "$proj round=$r v=$v $line same=$same load=$(cut -d' ' -f1 /proc/loadavg)"
    done
    r=$((r + 1))
  done
done
echo "# done $(date +%T)"
