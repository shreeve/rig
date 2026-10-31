#!/bin/bash
# screen.sh: every probe row for main and each finalist, 5 rounds each (rounds-mac.sh)
cd "$(dirname "$0")"
C=$(cat cands.txt)
for w in "insert 1000" "insert 100000" "insert 4000000" "sized 16" "sized 1000" "sized 100000" "random 16" "random 24" "random 1000" "random 1500" "ints"; do
  ./rounds-mac.sh 5 "$w" $C
done
