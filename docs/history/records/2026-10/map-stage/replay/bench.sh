#!/bin/sh
# bench.sh TRACE BIN ROUNDS CPU SIBLING LABEL DESIGN... [-- ARGS]: run the
# replay ROUNDS times for each DESIGN, interleaved, the order rotated each
# round, pinned to CPU, and print one line a run: the label, the round,
# the design, the sibling core's busy share during the run, and the
# replay's RESULT line. ARGS (after --) go to every run (--only, --pollute).
set -eu
trace=$1 bin=$2 rounds=$3 cpu=$4 sib=$5 label=$6
shift 6
designs=
while [ $# -gt 0 ] && [ "$1" != -- ]; do designs="$designs $1"; shift; done
[ $# -gt 0 ] && shift
extra="$*"
busy() { awk -v c="cpu$sib" '$1 == c { print $2 + $3 + $4 + $7 + $8, $2 + $3 + $4 + $5 + $6 + $7 + $8 }' /proc/stat; }
n=$(echo $designs | wc -w)
r=1
while [ $r -le $rounds ]; do
  i=0
  set -- $designs
  # rotate by the round number
  k=$(( (r - 1) % n )); while [ $k -gt 0 ]; do x=$1; shift; set -- "$@" $x; k=$((k - 1)); done
  for d in "$@"; do
    b0=$(busy)
    out=$(taskset -c "$cpu" "$bin" "$trace" "$d" $extra 2>&1 | grep RESULT)
    b1=$(busy)
    share=$(echo "$b0 $b1" | awk '{ t = $4 - $2; s = 0; if (t > 0) s = ($3 - $1) / t; printf "%.3f", s }')
    echo "$label round=$r design=$d sibling_busy=$share $out"
  done
  r=$((r + 1))
done
