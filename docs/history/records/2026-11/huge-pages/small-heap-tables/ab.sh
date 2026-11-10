#!/bin/bash
# ab.sh OUT: interleaved P-core A/B of plain Trig builds: base (a), its copy (b, A/A), the fix (f). Libs off, as the controlled check.
set -u
O=${1:-/zfs/rig-smallhuge/ab1}; mkdir -p $O; : > $O/runs
W=/zfs/rig-smallhuge; D=/tmp/smallhuge; EV=duration_time,cpu_core/cycles/u,cpu_core/instructions/u
C1=${C1:-3}; CN=${CN:-0-11}
export TRIG_PREBUILT_LIBS=0
fresh() { rm -rf $D; mkdir -p $D; cp $W/t-base $D/a; cp $W/t-base $D/b; cp $W/t-fix $D/f; echo "# fresh $(date +%T) free $(buddy)" >> $O/runs; }
buddy() { awk '{s+=$(NF-1)} END {print s}' /proc/buddyinfo; }
vm() { awk '/^(compact_stall|thp_fault_alloc|thp_fault_fallback) /{printf "%s=%s ",$1,$2}' /proc/vmstat; }
running() { ps -eLo psr=,stat=,comm= | awk '$1 <= 11 && $2 ~ /^R/ && $3 != "ps" && $3 != "awk" { f=1 } END { exit !f }'; }
quiet() { local i=0; while running && sleep 0.1 && running && [ $i -lt 20 ]; do i=$((i+1)); sleep 1; done; return 0; }
order() { echo "a b f" | tr " " "\n" | awk -v seed=$1 'BEGIN{srand(seed)} {print rand(),$0}' | sort -n | cut -d" " -f2 | tr "\n" " "; }
fresh; taskset -cp 13 $$ >/dev/null; echo "# start $(date +%T) load $(cut -d' ' -f1-3 /proc/loadavg) free $(buddy)"
run_proj() { # dir name rounds checkers...
  local dir=$1 proj=$2 N=$3; shift 3; cd $dir; cfg=tsconfig.trig.json; [ -f $cfg ] || cfg=tsconfig.json
  for c in "$@"; do
    if [ -n "${COMPACT:-}" ]; then sync; echo 1 | sudo -n tee /proc/sys/vm/compact_memory >/dev/null; sleep 4; echo "# compacted $proj c=$c free $(buddy)" >> $O/runs; fi
    if [ $c = 1 ]; then cores=$C1; a="--singleThreaded"; else cores=$CN; a="--checkers $c"; fi
    for v in a b f; do taskset -c $cores $D/$v -p $cfg --noEmit $a >/dev/null 2>&1; done
    for r in $(seq 1 $N); do quiet
      for v in $(order $((r+c*100))); do
        b0=$(buddy); v0=$(vm)
        /usr/bin/time -f "%M %R %S %U" -o $O/time taskset -c $cores perf stat --no-scale -x, -e $EV -o $O/perf $D/$v -p $cfg --noEmit $a >/dev/null 2>&1; e=$?
        v1=$(vm); b1=$(buddy)
        f=$(awk -F, '/^[0-9]/ {k=$3; sub("cpu_core/","",k); sub("/$","",k); printf "%s=%s ",k,$1}' $O/perf)
        read m rf s u < <(tail -n1 $O/time)
        echo "$proj c=$c round=$r v=$v ${f}rss_kb=$m minflt=$rf stime=$s utime=$u free=$b0>$b1 vm0 $v0 vm1 $v1 exit=$e" >> $O/runs
      done
    done
  done
}
P=/zfs/trig-pup/full/trig/misc/projects
for p in ${SMALL:-tiny-invariant mitt neverthrow}; do run_proj $P/$p $p ${RS:-60} ${CSS:-1 4 8}; done
[ -z "${NOBIG:-}" ] && { run_proj $P/ts-pattern ts-pattern ${RB:-20} 1 4 8; run_proj /zfs/trig-pup/trial/t3/projects/dify/packages/contracts contracts ${RB:-20} 1 4 8; }
echo "# done $(date +%T) free $(buddy)"
