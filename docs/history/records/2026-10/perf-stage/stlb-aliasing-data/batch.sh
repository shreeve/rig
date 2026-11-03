#!/bin/sh
# batch.sh STOPMODE PROJS REPS: sample each config. STOPMODE 0 = no scan; else a file of "proj arm kb" lines.
P=/zfs/trig-pup/full/trig/misc/projects
STOP=$1; PROJS=$2; REPS=${3:-1}
run() { # proj arm
  case $2 in
    trig1) k=trig; c=12;    set -- $1 $2 /tmp/hp/trigm -p tsconfig.trig.json --noEmit --singleThreaded ;;
    trig4) k=trig; c=12-15; set -- $1 $2 /tmp/hp/trigm -p tsconfig.trig.json --noEmit --checkers 4 ;;
    tsrs1) k=tsrs; c=12;    set -- $1 $2 env RAYON_NUM_THREADS=1 /tmp/hp/tsrspkg/tsrs -p tsconfig.trig.json --noEmit --checkerAssignment go --noLazyMembers --singleThreaded ;;
    tsrs4) k=tsrs; c=12-15; set -- $1 $2 env RAYON_NUM_THREADS=4 /tmp/hp/tsrspkg/tsrs -p tsconfig.trig.json --noEmit --checkerAssignment go --noLazyMembers --checkers 4 ;;
  esac
  proj=$1 arm=$2; shift 2
  kb=0; [ "$STOP" != 0 ] && kb=$(awk -v p=$proj -v a=$arm '$1==p && $2==a {print $3}' $STOP)
  echo "=== $proj $arm"
  python3 /tmp/hp/hps.py $k ${kb:-0} $P/$proj $c -- "$@"
}
for proj in $PROJS; do r=1; while [ $r -le $REPS ]; do
  for arm in ${ARMS:-trig1 trig4 tsrs1 tsrs4}; do run $proj $arm; done; r=$((r+1)); done; done
