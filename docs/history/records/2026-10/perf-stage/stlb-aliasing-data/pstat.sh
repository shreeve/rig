#!/bin/sh
# pstat.sh PROJS REPS: E-core perf counters for trig/tsrs, THP as the system gives it (thp) and THP off for the process (nothp).
P=/zfs/trig-pup/full/trig/misc/projects
PROJS=$1; REPS=${2:-5}
NOTHP="python3 -c import\ ctypes,os,sys;ctypes.CDLL(None).prctl(41,1,0,0,0);os.execvp(sys.argv[1],sys.argv[1:])"
EV=cpu_atom/cycles/u,cpu_atom/cycles/k,cpu_atom/instructions/u,cpu_atom/dtlb_load_misses.walk_completed/,cpu_atom/dtlb_load_misses.walk_completed_4k/,cpu_atom/dtlb_load_misses.walk_completed_2m_4m/,cpu_atom/ld_head.pgwalk_at_ret/,cpu_atom/ld_head.dtlb_miss_at_ret/,page-faults
one() { # proj arm mode
  proj=$1 arm=$2 mode=$3
  case $arm in
    trig1) c=12;    set -- /tmp/hp/trigm -p tsconfig.trig.json --noEmit --singleThreaded ;;
    trig4) c=12-15; set -- /tmp/hp/trigm -p tsconfig.trig.json --noEmit --checkers 4 ;;
    tsrs1) c=12;    set -- env RAYON_NUM_THREADS=1 /tmp/hp/tsrspkg/tsrs -p tsconfig.trig.json --noEmit --checkerAssignment go --noLazyMembers --singleThreaded ;;
    tsrs4) c=12-15; set -- env RAYON_NUM_THREADS=4 /tmp/hp/tsrspkg/tsrs -p tsconfig.trig.json --noEmit --checkerAssignment go --noLazyMembers --checkers 4 ;;
  esac
  pre=""
  if [ $mode = nothp ]; then
    case $arm in tsrs*) set -- env MIMALLOC_ALLOW_THP=0 "$@" ;; *) pre="python3 -c import\ ctypes,os,sys;ctypes.CDLL(None).prctl(41,1,0,0,0);os.execvp(sys.argv[1],sys.argv[1:])" ;; esac
  fi
  t0=$(awk '/thp_fault_alloc /{print $2}' /proc/vmstat)
  fb=$(awk '$4!="DMA"{n=0; for(o=14;o<=NF;o++) n+=$o*2^(o-14); s+=n} END{print s}' /proc/buddyinfo)
  cd $P/$proj
  if [ -n "$pre" ]; then W="python3 /tmp/hp/nothp.py"; else W=""; fi
  /usr/bin/time -f "%M" -o /tmp/hp/ps.time $W taskset -c $c perf stat --no-scale -x, -e $EV -o /tmp/hp/ps.perf "$@" > /dev/null 2>&1
  t1=$(awk '/thp_fault_alloc /{print $2}' /proc/vmstat)
  f=$(awk -F, '/^[0-9]/ { k=$3; sub("cpu_atom/", "", k); sub("/$", "", k); sub("dtlb_load_misses.", "L.", k); sub("dtlb_store_misses.", "S.", k); sub("ld_head.", "H.", k); printf "%s=%s(%s) ", k, $1, $5 }' /tmp/hp/ps.perf)
  echo "$proj $arm $mode $f rss_kb=$(tail -1 /tmp/hp/ps.time) thp_alloc_sys=$((t1-t0)) free2m=$fb"
}
for proj in $PROJS; do r=1; while [ $r -le $REPS ]; do
  for arm in ${ARMS:-trig1 tsrs1 trig4 tsrs4}; do for mode in thp nothp; do one $proj $arm $mode; done; done
  r=$((r+1)); done; done
