#!/bin/sh
# conc-audit: Trig plain base and no-yield-checks builds (Rig 928b44bf2,
# Trig baae9fe), optionally standing-6's PGO Trig, and shipped tsrs, at one
# checker (P-core 6, sibling 7 idle) and four (P-cores 0,6,8,10, siblings
# idle), every run with --extendedDiagnostics, rotated each round.
# time.sh N "PROJS" [PGO_BIN]
set -u
N=${1:-20}
PROJS=${2:-empty zod3 ts-pattern}
PGO=${3:-}
W=/zfs/worktrees/rig/conc-audit
B=$W/bin
TSRS=/zfs/trig-pup/tsrs-shipped/package/tsrs
V="base1 base4 noy1 noy4 tsrs1 tsrs4"
[ -n "$PGO" ] && V="$V pgo1 pgo4"
dir_of() { case $1 in empty) echo $W/empty ;; *) echo /zfs/trig-pup/full/trig/misc/projects/$1 ;; esac; }
cmd_of() {
  t="-p tsconfig.trig.json --noEmit --extendedDiagnostics"
  s="$t --checkerAssignment go --noLazyMembers"
  case $1 in
    base1) echo "taskset -c 6 $B/base $t --singleThreaded" ;;
    base4) echo "taskset -c 0,6,8,10 $B/base $t --checkers 4" ;;
    noy1) echo "taskset -c 6 $B/noyield $t --singleThreaded" ;;
    noy4) echo "taskset -c 0,6,8,10 $B/noyield $t --checkers 4" ;;
    pgo1) echo "taskset -c 6 $PGO $t --singleThreaded" ;;
    pgo4) echo "taskset -c 0,6,8,10 $PGO $t --checkers 4" ;;
    tsrs1) echo "taskset -c 6 env RAYON_NUM_THREADS=1 $TSRS $s --singleThreaded" ;;
    tsrs4) echo "taskset -c 0,6,8,10 env RAYON_NUM_THREADS=4 $TSRS $s --checkers 4" ;;
  esac
}
O=$W/time; mkdir -p $O
EV=duration_time,user_time,system_time,cpu_core/cycles/u,cpu_core/cycles/k,cpu_core/instructions/u,page-faults,cpu_core/dtlb_load_misses.walk_completed/u,cpu_core/dtlb_load_misses.walk_active/u,cpu_core/dtlb_store_misses.walk_completed/u,cpu_core/dtlb_store_misses.walk_active/u
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
# The output with the statistics lines (each ends in a number) left out.
body() { grep -v -E ': +[0-9.]+[sK]?$' "$1"; }
phase() { awk -v k="$2" -F': +' '$1 == k { v = $2; sub("s$", "", v); printf "%.0f", v * 1000 }' "$1"; }
run() { # run PROJ V -> fields
  e=0
  /usr/bin/time -f "%M %e %R" -o $O/time taskset -c 12-19 perf stat -x, -e $EV -o $O/perf $(cmd_of $2) > $O/out.$1.$2 2>&1 || e=$?
  f=$(awk -F, '/^[0-9]/ { k=$3; sub("cpu_core/", "", k); sub("/$", "", k); printf "%s=%s ", k, $1 }' $O/perf)
  p="parse_ms=$(phase $O/out.$1.$2 'Parse time') bind_ms=$(phase $O/out.$1.$2 'Bind time') check_ms=$(phase $O/out.$1.$2 'Check time') total_ms=$(phase $O/out.$1.$2 'Total time')"
  set -- $(tail -n 1 $O/time)
  echo "${f}${p} rss_kb=$1 minflt=$3 exit=$e"
}
echo "# start $(date +%T) N=$N load $(cut -d' ' -f1-3 /proc/loadavg) PGO=$PGO"
for proj in $PROJS; do
  cd $(dir_of $proj)
  quiet
  for v in $V; do run $proj $v > /dev/null; body $O/out.$proj.$v > $O/ref.$proj.$v; done
  for v in $V; do
    cmp -s $O/ref.$proj.$v $O/ref.$proj.tsrs1 && echo "# $proj: $v's output and tsrs1's are the same" || echo "# $proj: $v's output and tsrs1's DIFFER"
  done
  r=1
  while [ $r -le $N ]; do
    quiet
    set -- $V; k=$(( (r - 1) % $# )); while [ $k -gt 0 ]; do x=$1; shift; set -- "$@" $x; k=$((k - 1)); done
    for v in "$@"; do
      line=$(run $proj $v)
      body $O/out.$proj.$v > $O/cur
      same=1; cmp -s $O/ref.$proj.$v $O/cur || same=0
      echo "$proj round=$r v=$v $line same=$same load=$(cut -d' ' -f1 /proc/loadavg)"
    done
    r=$((r + 1))
  done
done
echo "# done $(date +%T)"
