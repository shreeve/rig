#!/bin/bash
# probe.sh file.rig... : check on head (f395daef) and base (faceba15); if head accepts, run debug+release sanitized and oracle
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad
H=$S/head/bin; B=$S/base/bin
mkdir -p $S/rv3
for f in "$@"; do
  n=$(basename $f .rig)
  hc=$($H/rig check $f 2>&1); hr=$?
  bc=$($B/rig check $f 2>&1); br=$?
  bs=$([ $br = 0 ] && echo acc || echo rej)
  if [ $hr != 0 ]; then
    echo "== $n: head REJ | base $bs"
    echo "$hc" | grep -E "error|hint" | head -6 | sed 's/^/   /'
    [ -n "$VERBOSE" ] && [ $br != 0 ] && echo "$bc" | grep error | head -3 | sed 's/^/   B: /'
    continue
  fi
  d=$(RIG_SANITIZE=1 timeout 120 $H/rig run $f 2>&1); dr=$?
  r=$(RIG_SANITIZE=1 timeout 300 $H/rig build --release -o $S/rv3/bin_$n $f 2>&1 && RIG_SANITIZE=1 timeout 60 $S/rv3/bin_$n 2>&1); rr=$?
  o=$($H/rig-oracle $f 2>&1); orr=$?
  echo "== $n: head ACC | base $bs | debug rc=$dr | release rc=$rr | oracle rc=$orr"
  echo "$d" | head -8 | sed 's/^/   D: /'
  [ "$d" != "$r" ] && echo "$r" | head -8 | sed 's/^/   R: /'
  [ $orr != 0 ] && echo "$o" | head -4 | sed 's/^/   O: /'
  rm -f $S/rv3/bin_$n
done
