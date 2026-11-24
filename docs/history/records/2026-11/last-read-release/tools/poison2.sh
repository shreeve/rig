#!/bin/bash
# poison2.sh PROJECT OPTS...: pass 2 only, with mkpoison.py's options (bits=N, nolib, file=K), from pass 1's err.
cd ~/cpuq/tmp/lastread
R=~/cpuq/tmp/lastread/runs
B=~/cpuq/tmp/lastread/cenp/trig
p=$1; shift
tag=pz2x$(echo "$@" | tr -c 'a-z0-9' '_')
python3 mkpoison.py $R/pz1-$p-c1.err $R/$tag-$p.tsv "$@" > /dev/null
LR_POISON=$R/$tag-$p.tsv ./run-lr.sh $B $R $tag $p c1 > /dev/null
echo "$p $* pass2=$(md5sum < $R/$tag-$p-c1.out | cut -c1-8) main=$(md5sum < $R/base1-$p-c1.out | cut -c1-8) $(grep ^LRP $R/$tag-$p-c1.err) $(grep -v '^LR\|^Command' $R/$tag-$p-c1.err | head -2)"
