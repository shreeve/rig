#!/bin/sh
# drive.sh ROUNDS "PROJ..." "SET..." "ARM..." : one pupe call per run on E-core 18, arms alternating (order flips each round).
PUPE="/Users/shreeve/Library/Application Support/Claude/side-session-notes/local_37939213-3170-48f2-b3d3-829d83dc1c14/pupe"
R=$1; PS=$2; SS=$3; AS=$4
for r in $(seq 1 $R); do
  for p in $PS; do for s in $SS; do
    if [ $((r % 2)) = 0 ]; then order=$(echo $AS | tr ' ' '\n' | tail -r | tr '\n' ' '); else order=$AS; fi
    for a in $order; do
      n=0
      until "$PUPE" 18 "sh /zfs/trig-pup/trial/dload/one.sh $a $p $s $r"; do
        rc=$?; [ $rc = 75 ] || { echo "run $a $p $s $r failed rc=$rc"; break; }
        n=$((n+1)); [ $n -gt 60 ] && { echo "slot kept pup busy; stopping"; exit 75; }
        sleep 30
      done
    done
  done; done
done
echo "drive done"
