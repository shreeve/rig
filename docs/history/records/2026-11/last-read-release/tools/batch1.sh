#!/bin/bash
# batch1.sh [TAG [BIN]]: the census build on six projects at c1 and c4, one run each (c1 and c4 on disjoint CPU sets).
# Output in ~/cpuq/tmp/lastread/runs.
cd ~/cpuq/tmp/lastread
R=~/cpuq/tmp/lastread/runs
TAG=${1:-cen}; BIN=${2:-$HOME/cpuq/tmp/lastread/cen/trig}
PROJS=${PROJS:-"typeorm nuxt webpack supabase-studio Compiler Compiler-Unions"}
( for p in $PROJS; do ./run-lr.sh $BIN $R $TAG $p c1; done ) &
( for p in $PROJS; do ./run-lr.sh $BIN $R $TAG $p c4; done ) &
wait
