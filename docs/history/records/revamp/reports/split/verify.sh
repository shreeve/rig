#!/bin/bash
cd /Users/shreeve/Data/Code/rig-rv-emit-verify
for c in bd091c3 8fa554f 5bbef69 bb6486c efc7309; do
  git checkout -q --detach $c
  echo "== $c $(git log --format=%s -1)"
  ./test/run -j 4 2>&1 | grep -E "FAIL|passed"
done
