#!/bin/zsh
# Usage: ./run.sh [probe.rig ...]  -- runs each probe on main and on text-core
MAIN=/Users/shreeve/Data/Code/rig/bin/rig
BR=/Users/shreeve/Data/Code/rig-text/bin/rig
cd ${0:A:h}
files=(${@:-*.rig})
for f in $files; do
  for which in main branch; do
    bin=$MAIN; [[ $which == branch ]] && bin=$BR
    out=$($bin run $f 2>&1)
    rc=$?
    if [[ $rc == 0 ]]; then res="OK: $(echo $out | tr '\n' '|' | cut -c1-110)"
    else res="ERR: $(echo $out | grep -m1 -E 'error|panic|leak' | sed 's/^[^:]*:[0-9]*:[0-9]*: //' | cut -c1-150)"; fi
    printf "%-28s %-6s %s\n" ${f:r} $which "$res"
  done
done
