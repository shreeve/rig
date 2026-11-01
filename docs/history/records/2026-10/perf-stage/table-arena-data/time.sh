#!/bin/sh
# time.sh N: item 15's P-core timing. Trig aa3994b built plain --release by
# Rig a5a78efbb (base) and by #832 (fix2; fix3 is its first half), and
# Trig checker-tasks ad9ad36 built by each (base-ct, fix2-ct). Each arm's
# binary is copied fresh first, so each starts with its file pages equally
# cached. One checker on P-core 6 (sibling 7 idle); four on P-cores
# 0,6,8,10 (siblings 5,7,9,11 idle). Rounds rotated. Fields as Merges'
# fix1/time.sh.
set -u
N=${1:-20}
W=/zfs/worktrees/rig/item15
P=/zfs/trig-pup/full/trig/misc/projects
ARMS=${ARMS:-base fix2 base-ct fix2-ct fix3}
O=$W/time; rm -rf $O; mkdir -p $O/bin
for a in $ARMS; do cp $W/v/$a/bin $O/bin/$a; done
EV=duration_time,user_time,system_time,cpu_core/cycles/u,cpu_core/cycles/k,cpu_core/instructions/u,cpu_core/instructions/k,page-faults
busy() {
  for _ in 1 2 3 4 5; do
    ps -eLo psr=,stat=,comm= | awk '($1==0||$1==5||$1==6||$1==7||$1==8||$1==9||$1==10||$1==11) && $2 ~ /^R/ && $3 != "ps" && $3 != "awk" { f=1 } END { exit !f }' && return 0
    sleep 0.2
  done
  return 1
}
quiet() {
  while pgrep -f "tools/full-main" > /dev/null; do echo "# $(date +%T) waiting: Trig's full suite"; sleep 60; done
  while busy; do echo "# $(date +%T) waiting: a process runs on the timing cores"; sleep 20; done
}
cores() { [ $1 = 1 ] && echo 6 || echo 0,6,8,10; }
dir() { [ $1 = empty ] && echo $W/empty || echo $P/$1; }
run() { # run PROJ ARM C -> fields
  e=0
  /usr/bin/time -f "%M %e %R" -o $O/time taskset -c 12-19 perf stat -x, -e $EV -o $O/perf taskset -c $(cores $3) $O/bin/$2 -p tsconfig.trig.json --noEmit --checkers $3 > $O/out.$1.$2.$3 2>&1 || e=$?
  f=$(awk -F, '/^[0-9]/ { k=$3; sub("cpu_core/", "", k); sub("/$", "", k); printf "%s=%s ", k, $1 }' $O/perf)
  set -- $(tail -n 1 $O/time)
  echo "${f}rss_kb=$1 minflt=$3 exit=$e"
}
echo "# start $(date +%T) N=$N load $(cut -d' ' -f1-3 /proc/loadavg)"
echo "# buddyinfo: $(tr -s ' ' < /proc/buddyinfo | tr '\n' '|')"
for job in empty:1 empty:4 mitt:1 mitt:4 neverthrow:1 neverthrow:4 zod3:4; do
  proj=${job%:*}; c=${job#*:}
  cd $(dir $proj)
  quiet
  set -- $ARMS; first=$1
  for a in $ARMS; do run $proj $a $c > /dev/null; cp $O/out.$proj.$a.$c $O/ref.$proj.$a.$c; done
  for a in $ARMS; do
    cmp -s $O/ref.$proj.$a.$c $O/ref.$proj.$first.$c && echo "# $proj/$c: $a's output and $first's are the same" || echo "# $proj/$c: $a's output and $first's DIFFER"
  done
  r=1
  while [ $r -le $N ]; do
    quiet
    set -- $ARMS; k=$(( (r - 1) % $# )); while [ $k -gt 0 ]; do x=$1; shift; set -- "$@" $x; k=$((k - 1)); done
    for a in "$@"; do
      line=$(run $proj $a $c)
      same=1; cmp -s $O/ref.$proj.$a.$c $O/out.$proj.$a.$c || same=0
      echo "$proj c=$c round=$r v=$a $line same=$same load=$(cut -d' ' -f1 /proc/loadavg)"
    done
    r=$((r + 1))
  done
done
echo "# buddyinfo: $(tr -s ' ' < /proc/buddyinfo | tr '\n' '|')"
echo "# done $(date +%T)"
