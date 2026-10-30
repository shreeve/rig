#!/bin/sh
# time.sh N: N rounds at each level of $MODES, one level after another; in
# each round, every arm of $V in an order rotated by the round, ts-pattern's
# rounds then zod3's, on P-core 1 with its sibling 2 idle.
#   natural: nothing is done to memory; the run starts with what free
#            2 MiB blocks pup has.
#   quiet:   unfrag first makes up to 256 free 2 MiB blocks (it compacts).
#   normal:  unfrag, then a fresh frag (frag.c) capped at 2 GiB fragments
#            free memory and takes all but 115 free 2 MiB blocks outside
#            DMA, holding them for this run alone (killed by its pid as the
#            run ends): pup's level on 2026-10-29 morning (88-139).
#   partly:  the same, leaving 55 (meant as thp-gate's partly
#            fragmented, 48-62; runs started at 54-85).
#   leaveN:  the same, leaving N (leave35 made thp-gate's 48-62).
#   light:   frag alone, taking every free 2 MiB block.
# frag never leaves less than 13 GiB available; startfrag waits while it
# cannot.
# One line per run: wall, user and system time, user and kernel cycles,
# user instructions, page faults, peak RSS, minor faults, exit, the free
# 2 MiB blocks outside DMA at the start and the end (units, units_end), the
# deltas of /proc/vmstat's THP and compaction counters over the run
# (system-wide), what frag held, whether the output matches the
# reference's (arm $REF), and the load.
set -u
MODES=${MODES:-"natural quiet normal partly light"}
N=${1:-10}
W=/zfs/worktrees/rig/thp-spare
P=$W/trig/misc/projects
. $W/cmds.sh
O=$W/time; mkdir -p $O
ARGS="-p tsconfig.trig.json --noEmit --singleThreaded"
KEYS="thp_fault_alloc thp_fault_fallback compact_stall compact_success compact_fail compact_migrate_scanned compact_isolated"
busy() {
  for _ in 1 2 3 4 5; do
    ps -eLo psr=,stat=,comm= | awk '($1 == 1 || $1 == 2) && $2 ~ /^R/ && $3 != "ps" && $3 != "awk" { f=1 } END { exit !f }' && return 0
    sleep 0.2
  done
  return 1
}
quiet() {
  while pgrep -f 'tools/full-main' > /dev/null; do echo "# $(date +%T) waiting: Trig's full suite is running"; sleep 60; done
  while busy; do echo "# $(date +%T) waiting: a process runs on core 1 or 2"; sleep 20; done
}
vm() { awk -v keys="$KEYS" 'BEGIN { n = split(keys, k); for (i = 1; i <= n; i++) w[k[i]] = i } ($1 in w) { v[w[$1]] = $2 } END { for (i = 1; i <= n; i++) printf "%s ", v[i] }' /proc/vmstat; }
units() { awk '$4 != "DMA" { for (i = 14; i <= NF; i++) u += $i * 2^(i - 14) } END { print u + 0 }' /proc/buddyinfo; }
FRAG=
startfrag() { # startfrag MAX_MAP_MB [LEAVE]: waits until frag can take its share with 13 GiB left
  while :; do
    taskset -c 1 $W/frag 13312 $1 ${2:-} > $O/frag.out 2>&1 &
    FRAG=$!
    while kill -0 $FRAG 2>/dev/null && ! grep -q "^ready" $O/frag.out; do sleep 0.2; done
    grep -q "^ready" $O/frag.out && return
    wait $FRAG 2>/dev/null; FRAG=
    echo "# $(date +%T) waiting: frag cannot leave 13 GiB available ($(awk "/MemAvailable/ { print int(\$2 / 1048576) }" /proc/meminfo) GiB now)" >&2
    sleep 20
  done
}
stopfrag() { [ -n "$FRAG" ] && kill $FRAG 2>/dev/null; wait $FRAG 2>/dev/null; FRAG=; sleep 2; }
trap 'stopfrag; exit 1' INT TERM HUP
run() { # run PROJ V MODE -> fields
  e=0
  u=$(units)
  set -- $1 $2 $3 $(vm)
  /usr/bin/time -f "%M %e %R" -o $O/time perf stat -x, -e duration_time,user_time,system_time,cpu_core/cycles/u,cpu_core/cycles/k,cpu_core/instructions/u,page-faults -o $O/perf taskset -c 1 $(bin_of $2) $ARGS > $O/out.$1.$2 2>&1 || e=$?
  after=$(vm)
  f=$(awk -F, '/^[0-9]/ { k=$3; sub("cpu_core/", "", k); sub("/$", "", k); printf "%s=%s ", k, $1 }' $O/perf)
  d=$(echo "$*" "|" $after | awk -v keys="$KEYS" '{ n = split(keys, k); for (i = 1; i <= n; i++) printf "%s=%d ", k[i], $(n + 4 + i) - $(3 + i) }')
  t=$(tail -n 1 $O/time)
  echo "${f}rss_kb=${t%% *} minflt=${t##* } exit=$e units=$u units_end=$(units) $d"
}
echo "# start $(date +%T) N=$N V=$V load $(cut -d' ' -f1-3 /proc/loadavg)"
for mode in $MODES; do
for proj in ts-pattern zod3; do
  cd $P/$proj
  quiet
  [ -s $O/ref.$proj ] || taskset -c 1 $(bin_of $REF) $ARGS > $O/ref.$proj 2>&1
  r=1
  while [ $r -le $N ]; do
    quiet
    set -- $V; k=$(( (r - 1) % $# )); while [ $k -gt 0 ]; do x=$1; shift; set -- "$@" $x; k=$((k-1)); done
    for v in "$@"; do
        case $mode in
          quiet) taskset -c 1 $W/unfrag 256 > $O/unfrag.out 2>&1 ;;
          normal) taskset -c 1 $W/unfrag 256 > $O/unfrag.out 2>&1; startfrag 2048 115 ;;
          partly) taskset -c 1 $W/unfrag 256 > $O/unfrag.out 2>&1; startfrag 2048 55 ;;
          leave*) taskset -c 1 $W/unfrag 256 > $O/unfrag.out 2>&1; startfrag 2048 ${mode#leave} ;;
          light) startfrag 2048 ;;
        esac
        line=$(run $proj $v $mode)
        case $mode in normal|partly|leave*|light) held=$(grep -o "held_mib=[0-9]*" $O/frag.out); stopfrag ;; *) held="held_mib=0" ;; esac
        same=1; cmp -s $O/ref.$proj $O/out.$proj.$v || { same=0; cp $O/out.$proj.$v $O/diff.$proj.$r.$v.$mode; }
        echo "$proj round=$r v=$v mode=$mode $line $held same=$same load=$(cut -d' ' -f1 /proc/loadavg)"
    done
    r=$((r + 1))
  done
done
done
echo "# done $(date +%T) load $(cut -d' ' -f1-3 /proc/loadavg)"
