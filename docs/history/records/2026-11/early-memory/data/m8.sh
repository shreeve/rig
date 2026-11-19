#!/bin/bash
# m8.sh: inside a slot. bench/tasks by its own driver (fastest of 9, 8 rounds, arms rotating: cur new aa d) at
# 12 workers on 0-11; the fork board (cur new aa d rayon, 20 rounds); peak RSS of fewtask and bench/tasks (cur new d).
D=/zfs/trig-pup/psum-gap/mem/b6; O=/zfs/trig-pup/psum-gap/mem/m8; mkdir -p $O; T=/zfs/trig-pup/rig-586e3939a
cd $T
arms="cur new aa d"
for k in $(seq 8); do set -- $arms; n=$(( k % 4 )); rot="${@:$((n+1))} ${@:1:$n}"
  for a in $rot; do RIG_WORKERS=12 taskset -c 0-11 timeout 300 python3 bench/tasks/bench-tasks --out $D/td-$a --time-only --reps 9 --variants rig-safe > $O/t-$a-$k.txt 2>&1 || echo "t $a $k rc=$?"; done; done; echo "tasks done"
taskset -c 8 python3 /zfs/trig-pup/runs/s1118-order-board.py 20 $O/fork-samples.txt cur=$D/fork-cur new=$D/fork-new aa=$D/fork-aa d=$D/fork-d rayon=$D/rayon > $O/fork.txt 2>&1; echo "fork rc=$?"
: > $O/rss.txt
for k in 1 2 3 4 5; do for a in cur new d; do for p in few tasks; do
  RIG_WORKERS=12 taskset -c 0-11 /usr/bin/time -v $D/$p-$a > /dev/null 2> $O/rss-err.tmp
  echo "$k $a $p $(grep 'Maximum resident' $O/rss-err.tmp | awk '{print $NF}')" >> $O/rss.txt; done
  for m in many idle; do RIG_WORKERS=12 taskset -c 0-11 /usr/bin/time -v $D/tasks-$a $m > /dev/null 2> $O/rss-err.tmp
    echo "$k $a tasks-$m $(grep 'Maximum resident' $O/rss-err.tmp | awk '{print $NF}')" >> $O/rss.txt; done
done; done; echo "rss done"
