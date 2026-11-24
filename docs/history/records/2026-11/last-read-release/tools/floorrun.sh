#!/bin/bash
# floorrun.sh MODE PROJECT...: the floors' replay: for floor 1 and floor 2, the table (floors.py, from the c1 census
# run cen4r1-PROJECT-c1 and main's stdout), then a run of the cen4 build at MODE with LR_FLOOR: released records
# overwritten with 0xA5 at the floor's release point, any hooked read of a released kind counted (LRV). Prints
# whether stdout equals main's, the groups and files released, and the violations.
cd ~/cpuq/tmp/lastread
R=$HOME/cpuq/tmp/lastread/runs
B=${BIN:-$HOME/cpuq/tmp/lastread/cen4/trig}
M=$1; shift
for p in "$@"; do
  for fl in 1 2; do
    t=$R/floor$fl-$p.tbl
    [ -s $t ] || python3 floors.py table $R/cen4r1-$p-c1.err $R/base1-$p-c1.out $fl $t > $R/floor$fl-$p.tbl.log
    LR_FLOOR=$t ./run-lr.sh $B $R fl$fl$TAG $p $M > /dev/null
    f=$R/fl$fl$TAG-$p-$M
    a=$(md5sum < $R/base1-$p-$M.out | cut -c1-8); b=$(md5sum < $f.out | cut -c1-8)
    echo "$p $M floor$fl $([ $a = $b ] && echo SAME || echo "DIFF($b)") $(grep ^LRFL $f.err | cut -f2-) viol=$(grep -c ^LRV $f.err) $(grep -v '^LR\|^Command' $f.err | head -2 | tr '\n' ' ') | $(cat $R/floor$fl-$p.tbl.log)"
  done
done
