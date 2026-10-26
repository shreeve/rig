#!/bin/sh
# sym.sh FILE BIN: each listprof line, then the inlined frames of its address.
while read -r _ kind a rest; do
  echo "== $kind $rest"
  addr2line -f -i -e $2 $(printf "%x" $((a - 1))) | paste - - | grep -v "runtime.zig\|ListProf" | head -3 | awk "{printf \"   %s %s\n\", \$1, \$2}" | sed "s|/zfs/trig-pup/trial/lg/prof/out/||"
done < $1
