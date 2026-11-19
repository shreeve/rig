#!/bin/bash
# claim1.sh: the growth micro (main, new, Rust; 15 rounds) and fork.rig's peak RSS (/usr/bin/time -l; main and new
# at p0, 1 and 10 workers, 5 interleaved runs).
G=$(cd $(dirname $0) && pwd)
bash $G/../grow/gb.sh 15 $G/grow-main $G/grow-new $G/../grow/grow-rust > $G/micro.txt
: > $G/rss.txt
for k in 1 2 3 4 5; do for a in main new; do for w in 1 10; do
  r=$(RIG_WORKERS=$w /usr/bin/time -l $G/fork-$a-p0 2>&1 >/dev/null | awk '/maximum resident/ {print $1}')
  echo "$k $a w$w $r" >> $G/rss.txt; done; done; done
for w in 1 10; do echo "rayon w$w $(RAYON_NUM_THREADS=$w /usr/bin/time -l $G/rayon-bin 2>&1 >/dev/null | awk '/maximum resident/ {print $1}')" >> $G/rss.txt; done
