#!/bin/bash
# prof4.sh OUT: where TLB flushes come from (kernel stacks), and page faults by the mapping they hit.
set -u
OUT=$1; B=/tmp/scal-probe; P=/zfs/trig-pup/full/trig/misc/projects
mkdir -p $OUT
t="-p tsconfig.trig.json --noEmit"
GO="--checkerAssignment go --noLazyMembers"
cores() { case $1 in 1) echo 12;; 4) echo 12-15;; 8) echo 12-19;; esac; }
cmd() { case $1 in
  trig) echo "$B/trig $t --checkers $2" ;;
  tsrsg) echo "env RAYON_NUM_THREADS=$2 $B/tsrs/tsrs $t $GO --checkers $2" ;; esac; }
for proj in ts-pattern zod3; do cd $P/$proj
  for c in 1 8; do k=$proj.trig.$c
    sudo -n perf record -q -e tlb:tlb_flush -g -o $OUT/tlb.$k.data -- setpriv --reuid=1000 --regid=1000 --init-groups bash -c "for i in 1 2; do taskset -c $(cores $c) $(cmd trig $c) > /dev/null 2>&1; done"
    sudo -n perf report -i $OUT/tlb.$k.data --stdio --no-children -G --percent-limit 2 --comm trig 2>/dev/null | head -400 > $OUT/tlb.$k.txt
    sudo -n chown 1000:1000 $OUT/tlb.$k.data
    perf record -q -e page-faults -c 1 -d -o $OUT/pf.$k.data taskset -c $(cores $c) $(cmd trig $c) > /dev/null 2>&1 &
    pp=$!; sleep 0.03; x=$(pgrep -P $pp | head -1); i=0
    while kill -0 $pp 2>/dev/null; do cat /proc/$x/smaps > $OUT/sm.$i 2>/dev/null; i=$((i+1)); sleep 0.05; done; wait $pp
    last=$(ls -v $OUT/sm.* | while read f; do [ -s $f ] && echo $f; done | tail -1); cp $last $OUT/smaps.$k; rm -f $OUT/sm.*
  done
done
