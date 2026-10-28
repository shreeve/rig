#!/bin/sh
# On pup: user cycles sampled every 4,000,037 cycles (about 1 kHz, perf's
# cap here), ts-pattern on core 8: 40 runs of the PGO build, 20 of the
# plain one, 10 of tsrs. prof/VARIANT.syms counts samples by symbol;
# prof/VARIANT.attr gives them by source line's file and function, inline
# frames included (attr.py).
set -u
W=/zfs/worktrees/rig/tsrs-standing
. $W/cmds.sh
O=$W/prof; mkdir -p $O
cd /zfs/trig-pup/full/trig/misc/projects/ts-pattern
for v in main-pgo main-rel tsrs; do
  case $v in main-pgo) n=40 ;; main-rel) n=20 ;; *) n=10 ;; esac
  : > $O/$v.all; : > $O/$v.ips
  for i in $(seq 1 $n); do
    perf record -q -e cpu_core/cycles/u -c 4000037 -o $O/$v.$i.data taskset -c 8 $(cmd_of $v) > /dev/null 2>&1
    perf script -i $O/$v.$i.data -F sym 2>/dev/null | sed 's/^ *//' >> $O/$v.all
    perf script -i $O/$v.$i.data -F ip 2>/dev/null | sed 's/^ *//' >> $O/$v.ips
    [ $i = 1 ] || rm -f $O/$v.$i.data
  done
  sort $O/$v.all | uniq -c | sort -rn > $O/$v.syms; rm $O/$v.all
done
for v in main-pgo main-rel; do
  b=$(cmd_of $v | cut -d' ' -f1)
  python3 $W/attr.py $b $O/$v.ips $O/$v.tsv > $O/$v.attr
done
echo "# done"
