#!/bin/sh
# heaps.sh CMD...: run CMD with the probe's log; count heaps by the last size each logged
RIG_PF_LOG=1 RIG_PF_MB=0 "$@" 2>&1 >/dev/null | grep "^pf" | awk '{h[$3]=$4} END {for (k in h) print h[k]}' | sort | uniq -c | tr "\n" " "; echo
