#!/bin/bash
for f in /Users/shreeve/Data/Code/rig/examples/*.rig; do
  b=$(basename $f .rig)
  exp=$(/Users/shreeve/Data/Code/rig/bin/rig run $f 2>&1)
  /Users/shreeve/Data/Code/rig/bin/rig build --release=fast -o rf_$b $f >/dev/null 2>&1 || { echo "$b BUILD FAIL"; continue; }
  got=$(./rf_$b 2>&1)
  gs=$(./bin_$b 2>&1)
  if [ "$exp" = "$got" ] && [ "$exp" = "$gs" ]; then echo "$b same"; else echo "$b DIFF"; fi
done
