#!/bin/bash
# gb.sh ROUNDS ARMS...: grow micro, each case each arm once a round, arms rotating; rows to stdout.
R=$1; shift; arms=("$@"); n=${#arms[@]}
for k in $(seq $R); do for c in span map push; do for j in $(seq 0 $((n-1))); do a=${arms[$(( (j+k) % n ))]}
  echo "$k ${a##*/} $($a $c)"; done; done; done
