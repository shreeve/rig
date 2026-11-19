#!/bin/bash
# build.sh: the Mac arms. main = b7bb1df1d, new = list-grow's bin/rig; fork.rig at three placements (p0 as it
# is, p1 and p2 with one and two never-taken prints after qsort's), Rayon's fork-order twin, the growth micro,
# rsort for the std sort board.
set -eu
G=$(cd $(dirname $0) && pwd); W=~/Data/Code/worktrees/rig/list-grow; H=$W/tools/heavy
MAIN=$($W/tools/baseline b7bb1df1d 2>/dev/null); NEW=$W/bin/rig
for a in main:$MAIN new:$NEW; do n=${a%%:*}; r=${a#*:}
  for p in 0 1 2; do RIG_OUT_DIR=$G/pkg-$n-$p $H $r build --release -o $G/fork-$n-p$p $G/p$p.rig; done
  RIG_OUT_DIR=$G/pkg-grow-$n $H $r build --release -o $G/grow-$n $G/../grow/grow.rig
  RIG_OUT_DIR=$G/pkg-rsort-$n $H $r build --release -o $G/rsort-$n $W/docs/history/records/2026-11/std-sort/programs/rsort.rig
done
cp $G/fork-main-p1 $G/fork-aa-p1
mkdir -p $G/rayon && cp -R $W/docs/history/records/2026-11/fork-order/rayon/. $G/rayon/
(cd $G/rayon && CARGO_TARGET_DIR=$G/rayon-target $H cargo build --release -q)
cp $G/rayon-target/release/fork-rayon $G/rayon-bin 2>/dev/null || cp $(ls $G/rayon-target/release/* | grep -v '\.d$' | head -1) $G/rayon-bin
ls -la $G | grep -E "fork-|grow-|rsort-|rayon-bin"
