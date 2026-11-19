#!/bin/bash
# m7.sh ROUNDS: inside a slot. The fork board (fork-order's fork.rig: cur, new, aa, pre, Rayon; 1 worker on core 6,
# 12 on 0-11), bench/tasks' rows at 12 workers on 0-11 (arms rotating), then peak RSS (/usr/bin/time -v,
# RIG_WORKERS=12 on 0-11, 5 interleaved rounds) of fewtask, bench/tasks and fork.
D=/zfs/trig-pup/psum-gap/mem/b6; O=/zfs/trig-pup/psum-gap/mem/m7; mkdir -p $O; R=$1
taskset -c 8 python3 /zfs/trig-pup/runs/s1118-order-board.py $R $O/fork-samples.txt cur=$D/fork-cur new=$D/fork-new aa=$D/fork-aa pre=$D/fork-pre rayon=$D/rayon > $O/fork.txt 2>&1; echo "fork rc=$?"
arms="cur new aa pre"
for k in $(seq $R); do set -- $arms; n=$(( k % 4 )); rot="${@:$((n+1))} ${@:1:$n}"
  for a in $rot; do RIG_WORKERS=12 taskset -c 0-11 $D/tasks-$a | sed "s/^/$k $a /" >> $O/tasks.txt; done; done; echo "tasks done"
: > $O/rss.txt
for k in 1 2 3 4 5; do for a in cur new pre; do for p in few tasks fork; do
  RIG_WORKERS=12 taskset -c 0-11 /usr/bin/time -v $D/$p-$a > $O/rss-out.tmp 2> $O/rss-err.tmp
  echo "$k $a $p rc=$? $(grep 'Maximum resident' $O/rss-err.tmp | awk '{print $NF}') $(tr '\n' ' ' < $O/rss-out.tmp | cut -c1-100)" >> $O/rss.txt
done
  for m in many idle; do RIG_WORKERS=12 taskset -c 0-11 /usr/bin/time -v $D/tasks-$a $m > /dev/null 2> $O/rss-err.tmp
    echo "$k $a tasks-$m rc=$? $(grep 'Maximum resident' $O/rss-err.tmp | awk '{print $NF}')" >> $O/rss.txt; done
done; done; echo "rss done"
