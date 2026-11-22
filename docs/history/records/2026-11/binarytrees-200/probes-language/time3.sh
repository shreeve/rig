#!/bin/bash
cd "$(dirname "$0")"
for r in 1 2 3 4 5 6 7; do
  for f in model_ptr16 model_ptr16pre model_rel32 model_rel32pre fast; do
    /usr/bin/time -l ./$f 21 > out.txt 2> t.err
    w=$(grep -E ' real ' t.err | awk '{print $1}')
    u=$(grep -E ' real ' t.err | awk '{print $3+$5}')
    m=$(grep 'maximum resident' t.err | awk '{printf "%d", $1/1048576}')
    echo "$r $f $w $u $m"
  done
done
