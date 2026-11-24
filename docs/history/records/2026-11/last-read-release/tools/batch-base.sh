#!/bin/bash
# batch-base.sh: main (base, native 32 units) on six projects at c1 and c4, three runs each: reference stdout and
# burst's peak RSS. Output in ~/cpuq/tmp/lastread/runs.
cd ~/cpuq/tmp/lastread
R=~/cpuq/tmp/lastread/runs
PROJS="typeorm nuxt webpack supabase-studio Compiler Compiler-Unions"
( for r in 1 2 3; do for p in $PROJS; do ./run-lr.sh ~/cpuq/tmp/lastread/base/trig $R base$r $p c1; done; done ) &
( for r in 1 2 3; do for p in $PROJS; do ./run-lr.sh ~/cpuq/tmp/lastread/base/trig $R base$r $p c4; done; done ) &
wait
