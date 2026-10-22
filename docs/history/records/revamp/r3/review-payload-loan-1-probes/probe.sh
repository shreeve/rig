#!/bin/bash
# probe.sh file...: head check / sanitize run / release run / oracle / main check
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad
for f in "$@"; do f=$(cd $(dirname $f) && pwd)/$(basename $f)
  n=$(basename $f .rig)
  hc=$($S/head/bin/rig check $f 2>&1 | head -3 | tr '\n' ' ')
  mc=$($S/main/bin/rig check $f 2>&1 | head -1 | tr '\n' ' ')
  echo "== $n"
  echo "  head: ${hc:-ACCEPT}"
  echo "  main: ${mc:-ACCEPT}"
  if [ -z "$hc" ]; then
    out=$(cd $S && RIG_SANITIZE=1 timeout 60 $S/head/bin/rig run $f 2>&1 | tail -4 | tr '\n' '|'); echo "  san: $out"
    out=$(cd $S && timeout 120 $S/head/bin/rig build --release -o $S/rel_$n $f 2>&1 && timeout 20 $S/rel_$n 2>&1 | tail -3 | tr '\n' '|'); echo "  rel: $out"; rm -f $S/rel_$n
  fi
  o=$($S/head/bin/rig-oracle $f 2>&1 | grep -E "DIFF|error|stricter|looser|prod=" | head -3 | tr '\n' ' '); echo "  oracle: ${o:-silent}"
done
