#!/bin/bash
# claim.sh LABEL MINUTES CMD...: tools/mac-claim, retried while it gives up
# waiting (exit 75); holds off while ~/Data/Code/mumps-compare/.mac-quiet exists.
L=$1; M=$2; shift 2
while :; do
  while [[ -e ~/Data/Code/mumps-compare/.mac-quiet ]]; do sleep 30; done
  /Users/shreeve/Data/Code/rig/tools/mac-claim --minutes "$M" "$L" "$@"; c=$?
  [[ $c == 75 ]] || exit $c
done
