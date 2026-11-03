#!/bin/sh
# ins.sh ROUNDS PROJECT CHECKERS ARMS...: interleaved, user instructions, cycles and peak memory a run, /usr/bin/time -l
W=$(cd "$(dirname "$0")" && pwd); P=/Users/shreeve/Data/Code/trig/misc/projects
n=$1; p=$2; c=$3; shift 3
cd $P/$p
i=1
while [ $i -le $n ]; do
  for v in "$@"; do
    /usr/bin/time -l $W/$v/bin -p $([ -f tsconfig.trig.json ] && echo tsconfig.trig.json || echo tsconfig.json) --noEmit --checkers $c > /dev/null 2> $W/t.tmp
    ins=$(awk '/instructions retired/ {print $1}' $W/t.tmp); cyc=$(awk '/cycles elapsed/ {print $1}' $W/t.tmp)
    rss=$(awk '/peak memory footprint/ {print $1}' $W/t.tmp); mr=$(awk '/maximum resident set size/ {print $1}' $W/t.tmp)
    real=$(awk '/ real / {print $1}' $W/t.tmp)
    echo "$p $c $v $i ins=$ins cyc=$cyc peak=$rss maxrss=$mr real=$real"
  done
  i=$((i + 1))
done
