#!/bin/sh
# counters.sh R: R interleaved rounds of perf stat, per project, for:
#   t773/t2c0/tsgo at one checker on core 12 (n=1), at four checkers on
#   core 12 alone (n=4on1: the same work with no other core busy), and at
#   four on E-cores 12-15 (n=4); tsrs default at four on 12-15.
# Counted on the process: E-core user cycles and instructions, LLC
# (longest-latency cache) misses and references, dTLB load misses, load
# stalls on memory and on page walks, page faults, TLB flushes, munmap,
# madvise, mmap and mremap calls, and function-call IPIs (TLB shootdowns
# arrive as these). Around it, system-wide, the memory controller's bytes.
# Then, once each, peak Rss and AnonHugePages (smaps_rollup every 5 ms),
# and each madvise call's advice and length.
set -u
R=${1:-5}
. /zfs/worktrees/rig/scaling-2/cmds.sh
O=$W/counters; mkdir -p $O
EV="cpu_atom/cycles/u,cpu_atom/instructions/u,cpu_atom/longest_lat_cache.miss/,cpu_atom/longest_lat_cache.reference/,cpu_atom/dTLB-load-misses/,cpu_atom/mem_bound_stalls_load.all/,cpu_atom/ld_head.pgwalk_at_ret/"
SW="duration_time,task-clock,page-faults,tlb:tlb_flush,syscalls:sys_enter_munmap,syscalls:sys_enter_madvise,syscalls:sys_enter_mmap,syscalls:sys_enter_mremap,irq_vectors:call_function_entry,irq_vectors:call_function_single_entry"
busy() {
  for _ in 1 2 3 4 5; do
    ps -eLo psr=,stat=,comm= | awk '$1 >= 12 && $1 <= 15 && $2 ~ /^R/ && $3 != "ps" && $3 != "awk" { f=1 } END { exit !f }' && return 0
    sleep 0.2
  done
  return 1
}
quiet() { while busy; do echo "# $(date +%T) waiting: a process runs on cores 12-15"; sleep 20; done; }
cmdn() { # cmdn V N: the command and its cores
  case $2 in
    1) echo "12 $(cmd_of $1 1)" ;;
    4on1) echo "12 $(cmd_of $1 4)" ;;
    4) echo "12-15 $(cmd_of $1 4)" ;;
  esac
}
stat1() { # stat1 PROJ V N
  set -- $1 $2 $3 $(cmdn $2 $3)
  p=$1 v=$2 n=$3 c=$4; shift 4
  sudo perf stat -a -x, -e uncore_imc_free_running/data_total/ -o $O/imc -- perf stat -x, -e $EV -e $SW -o $O/st -- taskset -c $c "$@" > /dev/null 2>&1
  f=$(awk -F, '/^[0-9]/ { k=$3; sub("cpu_atom/", "", k); sub("/$", "", k); gsub("/", "", k); printf "%s=%s ", k, $1 }' $O/st)
  m=$(awk -F, '/^[0-9]/ { printf "imc_mib=%s", $1 }' $O/imc)
  echo "$p v=$v n=$n $f$m load=$(cut -d' ' -f1 /proc/loadavg)"
}
smaps() { # smaps PROJ V N: peak Rss and AnonHugePages, sampled every 5 ms
  set -- $1 $2 $3 $(cmdn $2 $3)
  p=$1 v=$2 n=$3 c=$4; shift 4
  taskset -c $c "$@" > /dev/null 2>&1 &
  pid=$!; rss=0; ahp=0
  while kill -0 $pid 2>/dev/null; do
    set -- $(awk '/^Rss:/ { r=$2 } /^AnonHugePages:/ { a=$2 } END { print r+0, a+0 }' /proc/$pid/smaps_rollup 2>/dev/null) 0 0
    [ "$1" -gt $rss ] && rss=$1; [ "$2" -gt $ahp ] && ahp=$2
    sleep 0.005
  done
  wait $pid
  echo "$p v=$v n=$n peak_rss_kb=$rss peak_anon_huge_kb=$ahp"
}
madv() { # madv PROJ V N: madvise calls by advice: count and MiB
  set -- $1 $2 $3 $(cmdn $2 $3)
  p=$1 v=$2 n=$3 c=$4; shift 4
  sudo perf record -q -e syscalls:sys_enter_madvise -o $O/madv.data -- taskset -c $c "$@" > /dev/null 2>&1
  sudo perf script -i $O/madv.data -F trace 2>/dev/null | awk -v h="$p v=$v n=$n" '{ for (i = 1; i <= NF; i++) { if ($i == "len_in:") l = strtonum($(i+1)); if ($i == "behavior:") b = strtonum($(i+1)) } n[b]++; s[b] += l } END { printf "%s", h; for (b in n) printf " advice%d=%d/%.1fMiB", b, n[b], s[b] / 1048576; print "" }'
  sudo rm -f $O/madv.data
}
echo "# start $(date +%T) R=$R load $(cut -d' ' -f1-3 /proc/loadavg)"
for proj in ts-pattern zod3; do
  cd $P/$proj
  r=1
  while [ $r -le $R ]; do
    quiet
    for n in 1 4on1 4; do
      for v in t773 t2c0 tsgo; do echo "$(stat1 $proj $v $n) round=$r"; done
    done
    echo "$(stat1 $proj tsdef 4) round=$r"
    r=$((r + 1))
  done
  quiet
  for n in 1 4on1 4; do for v in t773 t2c0 tsgo; do smaps $proj $v $n; done; done
  for n in 1 4; do for v in t773 t2c0; do madv $proj $v $n; done; done
done
echo "# done $(date +%T) load $(cut -d' ' -f1-3 /proc/loadavg)"
