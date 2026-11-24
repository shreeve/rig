#!/bin/bash
# poison.sh PROJECT...: the validation pass at c1: a census run of the poison build (pass 1), its table (mkpoison.py),
# then a run with each file's tree, positions, text and names overwritten with 0xA5 right after the census says their
# last read happened (pass 2). Pass 2's stdout must equal main's; a read the hooks miss would see the 0xA5 bytes.
cd ~/cpuq/tmp/lastread
R=~/cpuq/tmp/lastread/runs
B=~/cpuq/tmp/lastread/cenp/trig
for p in "$@"; do
  ./run-lr.sh $B $R pz1 $p c1 > /dev/null
  python3 mkpoison.py $R/pz1-$p-c1.err $R/pz-$p.tsv ${NOLIB:-} > /dev/null
  LR_POISON=$R/pz-$p.tsv ./run-lr.sh $B $R pz2 $p c1 > /dev/null
  echo "$p pass1=$(md5sum < $R/pz1-$p-c1.out | cut -c1-8) pass2=$(md5sum < $R/pz2-$p-c1.out | cut -c1-8) main=$(md5sum < $R/base1-$p-c1.out | cut -c1-8) $(grep ^LRP $R/pz2-$p-c1.err) $(grep -v '^LR\|^Command' $R/pz2-$p-c1.err | head -3)"
done
