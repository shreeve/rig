#!/bin/bash
# usage: chk.sh path (file or dir)
cd /Users/shreeve/Data/Code/rig-rv-fe
p=$1; f=$p; [ -d "$p" ] && f=$p/main.rig
out=$(bin/rig check "$f" 2>&1); rc=$?
echo "== $p rc=$rc"; echo "$out"
grep -E '^# error:' "$f" | sed 's/^# error: //' | while IFS= read -r e; do
  if [[ "$e" =~ ^([0-9]+):([0-9]+):\ (.*)$ ]]; then
    L=${BASH_REMATCH[1]}; C=${BASH_REMATCH[2]}; t=${BASH_REMATCH[3]}
    echo "$out" | grep -F ":$L:$C:" | grep -qF -- "$t" && echo "  OK  $e" || echo "  MISS $e"
  else
    echo "$out" | grep -qF -- "$e" && echo "  OK  $e" || echo "  MISS $e"
  fi
done
