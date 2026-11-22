#!/bin/bash
# Interleaved rounds of each probe at n=21: wall, user+sys, peak RSS.
cd "$(dirname "$0")"
for r in 1 2 3 4 5 6 7; do
  for f in plain plainsplit fast wide fresh fastdepth; do
    /usr/bin/time -l ./$f 21 2> t.err > out.txt
    w=$(grep -E ' real ' t.err | awk '{print $1}')
    u=$(grep -E ' real ' t.err | awk '{print $3+$5}')
    m=$(grep 'maximum resident' t.err | awk '{printf "%d", $1/1048576}')
    echo "$r $f $w $u $m $(md5 -q out.txt)"
  done
done
