#!/bin/bash
# build.sh NAME RIG: fork.rig and fork3.rig at three placements, release.
set -e
S=${S:?scratch folder}
cd $S/src
for p in "" -p1 -p2; do
  "$2" build --release -o $S/bin/$1-fork$p fork$p.rig
  "$2" build --release -o $S/bin/$1-fork3$p fork3$p.rig
done
