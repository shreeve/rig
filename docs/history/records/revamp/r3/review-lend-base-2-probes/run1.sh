#!/bin/bash
# run1.sh file.rig -> writes file.res
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad
H=$S/r2head/bin
f=$1; n=${f%.rig}
d=$(RIG_SANITIZE=1 timeout 300 $H/rig run $f 2>&1); dr=$?
b=$n.bin
r=$(RIG_SANITIZE=1 timeout 600 $H/rig build --release -o $b $f 2>&1 && RIG_SANITIZE=1 timeout 60 $b 2>&1); rr=$?
rm -f $b
o=$($H/rig-oracle $f 2>&1); orr=$?
{ echo "D $dr"; echo "$d"; echo "R $rr"; echo "$r"; echo "O $orr"; echo "$o"; } > $n.res
